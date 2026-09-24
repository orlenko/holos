import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// People and voice profiles (docs/meeting-design.md §4.10, §5.9 PR10): VoiceProfileService, the extractors, and
// post-processing stage 7, with fake extractors and FakeDiarizer on generated audio. Helpers are prefixed `profile`.

// MARK: - Helpers

private let profileModel = DiarizationEngineInfo.fake.embeddingModel

/// A people store inside the test's temporary folder.
private func profileStore(_ temp: TemporaryDirectory) -> SpeakerProfileStore {
    SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
}

private func profileAxis(_ index: Int) -> [Float] {
    var values = [Float](repeating: 0, count: 8)
    values[index] = 1
    return values
}

private func profileUnit(_ values: [Float]) -> [Float] {
    let norm = values.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
    return values.map { Float(Double($0) / norm) }
}

private func profileClose(_ a: [Float], _ b: [Float], tolerance: Double = 1e-5) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs(Double($0) - Double($1)) <= tolerance }
}

/// A voice extractor that records what it is asked and returns an embedding for every requested turn: `vectors[id]`,
/// else `fallback`. `hook` runs first with the call number (from 1), so a test can pause it or edit meanwhile.
private final class ProfileFakeExtractor: VoiceSampleExtractor {
    struct Request: Equatable, Sendable {
        var track: String
        var turnIDs: [String]
    }

    private let calls = SharedValue<[Request]>([])
    let vectors: [String: [Float]]
    let fallback: [Float]
    let hook: (@Sendable (Int) async throws -> Void)?

    init(vectors: [String: [Float]] = [:], fallback: [Float] = profileUnit([0.6, 0.8, 0, 0, 0, 0, 0, 0]),
         hook: (@Sendable (Int) async throws -> Void)? = nil) {
        self.vectors = vectors; self.fallback = fallback; self.hook = hook
    }

    var requests: [Request] { calls.value }

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        let call = calls.update { requests -> Int in
            requests.append(Request(track: track, turnIDs: turns.map(\.id)))
            return requests.count
        }
        try await hook?(call)
        return turns.map { turn in
            TurnEmbedding(turnID: turn.id, speechSeconds: turn.end - turn.start,
                          vector: FloatVector(vectors[turn.id] ?? fallback))
        }
    }
}

/// A finished call session whose head run labels the system track: S1 has T1 and T3, S2 has T2 and T4, each turn
/// about 2.9 s (docs of `SessionFixtures.labelledSession`).
private func profileSession(in temp: TemporaryDirectory, speakers: [String] = ["S1", "S2"],
                            duration: Double = 20) async throws -> (session: URL, run: DiarizationRun) {
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: speakers, duration: duration)
    return (fixture.session, fixture.run)
}

/// An in-person session post-processed with FakeDiarizer: speakers mic:S1 (T1, T3) and mic:S2 (T2, T4), whose
/// centroids are axes 0 and 1. `forceVoiceData` writes the evaluation voice file.
private func profileProcessedSession(in temp: TemporaryDirectory, store: SpeakerProfileStore?,
                                     forceVoiceData: Bool = false) async throws -> (URL, PostProcessingRecord) {
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let processor = MeetingPostProcessor(diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]),
                                         options: PostProcessingOptions(forceVoiceData: forceVoiceData),
                                         freeSpace: FixedFreeSpace(.max), profiles: store)
    let record = try await processor.run(session: session, lease: nil)
    return (session, record)
}

/// A person with one sample of `vector` from another meeting.
private func profilePerson(_ id: String, _ name: String, vector: [Float], condition: RecordingCondition = .room,
                           session: String = UUID().uuidString) -> SpeakerProfile {
    SpeakerProfile(id: id, displayName: name, embeddingModel: profileModel, samples: [
        VoiceprintSample(sessionID: session, sessionName: "Earlier meeting", speakerIDs: ["mic:S1"], speechSeconds: 60,
                         embedding: FloatVector(vector), condition: condition, weak: false),
    ])
}

private func profileManifestID(_ session: URL) throws -> String { try SessionArchive.readManifest(at: session).id }

/// Polls `condition` every 5 ms for up to 10 s.
private func profileEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func profileView(_ session: URL, store: SpeakerProfileStore) throws -> SpeakerProjection {
    try #require(try SpeakerSessionSnapshot.load(
        session: session, profileNames: VoiceProfileService.profileNames(store: store)).projection)
}

/// The base64 text of every axis vector of 8 (FakeDiarizer's centroids and windows) and of `extra`.
private func profileVectorTexts(_ extra: [[Float]] = []) -> [String] {
    ((0..<8).map(profileAxis) + extra).map { values in
        let encoded = (try? HolosJSON.encoder(pretty: false).encode(FloatVector(values))) ?? Data()
        return String(decoding: encoded, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

/// Session files that contain one of `texts`.
private func profileFilesContaining(_ texts: [String], in session: URL) -> [String] {
    SessionFixtures.files(in: session).compactMap { path, data in
        let text = String(decoding: data, as: UTF8.self)
        return texts.contains(where: text.contains) ? path : nil
    }
}

// MARK: - Post-processing (stage 7)

@Test(.timeLimit(.minutes(1)))
func rememberOffMeansNoVoiceDataAndNoRecognition() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0))] }
    let (session, record) = try await profileProcessedSession(in: temp, store: store)
    #expect(record.state == .succeeded)
    let recognize = try #require(record.stages.last { $0.stage == .recognize })
    #expect(recognize.result == .skipped)
    #expect(recognize.message == RecognizeStage.rememberOff)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
    #expect(!SessionFixtures.exists(session.appendingPathComponent("speakers/recognition")))
    let runID = try #require(record.runID)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session) == nil)
    #expect(profileFilesContaining(profileVectorTexts(), in: session).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func rememberOnWritesRecognitionOnly() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0))]
    }
    let (session, record) = try await profileProcessedSession(in: temp, store: store)
    #expect(record.state == .succeeded)
    #expect(record.stages.map(\.stage) == [.transcript, .render, .diarize, .align, .recognize, .export])
    #expect(record.stages.last { $0.stage == .recognize }?.result == .succeeded)
    let runID = try #require(record.runID)
    let recognition = try #require(try SessionSpeakerStore.readRecognition(runID: runID, session: session))
    #expect(recognition.matches.map(\.speakerID) == ["mic:S1"])
    #expect(recognition.matches.map(\.profileID) == ["JIM"])
    #expect(recognition.matches.map(\.tier) == [.possible])
    #expect(recognition.embeddingModel == profileModel)
    // Distances only: no voice file and no vector anywhere in the session.
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
    #expect(profileFilesContaining(profileVectorTexts(), in: session).isEmpty)
    // The suggestion shows in the labels, never in the exports.
    let view = try profileView(session, store: store)
    #expect(view.speakers.first { $0.id == "mic:S1" }?.suggestion?.profileName == "Jim")
    for ext in ["md", "json", "txt"] {
        #expect(!SessionFixtures.text(SessionPaths.export(ext, in: session)).contains("Jim"))
    }
}

@Test(.timeLimit(.minutes(1)))
func enrollmentNeverFromAutomaticMatch() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let calibrated = RecognitionThresholds(likelyMaxDistance: 0.25, likelyMinMargin: 0.10, possibleMaxDistance: 0.43,
                                           minSampleSeconds: 20)
    let jim = profilePerson("JIM", "Jim", vector: profileAxis(0))
    try store.update {
        $0.rememberVoices = true
        $0.calibratedThresholds = calibrated
        $0.calibratedModel = profileModel
        $0.profiles = [jim]
    }
    let (session, record) = try await profileProcessedSession(in: temp, store: store)
    let runID = try #require(record.runID)
    let recognition = try #require(try SessionSpeakerStore.readRecognition(runID: runID, session: session))
    #expect(recognition.matches.map(\.tier) == [.likely])
    let view = try profileView(session, store: store)
    #expect(view.speakers.first { $0.id == "mic:S1" }?.label == "Jim (auto)")
    // A refresh finds nothing to learn: only confirmed links make samples.
    let extractor = ProfileFakeExtractor()
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    #expect(extractor.requests.isEmpty)
    #expect(try store.load().profiles.map { $0.samples.map(\.id) } == [jim.samples.map(\.id)])
}

// MARK: - Linking and enrollment

@Test(.timeLimit(.minutes(1)))
func enrollExtractsOnlyTheConfirmedSpeaker() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, run) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    let snapshot = try await VoiceProfileService.link(
        session: session, speakerID: "system:S2", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)

    #expect(extractor.requests == [.init(track: "system", turnIDs: ["T2", "T4"])])
    let database = try store.load()
    let jim = try #require(database.profiles.first)
    #expect(database.profiles.count == 1)
    #expect(jim.displayName == "Jim")
    #expect(jim.embeddingModel == profileModel)
    let sample = try #require(jim.samples.first)
    #expect(jim.samples.count == 1)
    #expect(sample.sessionID == (try profileManifestID(session)))
    #expect(sample.sessionName == "Fixture meeting")
    #expect(sample.speakerIDs == ["system:S2"])
    #expect(sample.condition == .call)
    #expect(sample.weak)
    #expect(sample.generation?.hasPrefix(run.id + ":") == true)
    #expect(sample.inputDigest != nil)
    #expect(profileClose(sample.embedding.values, extractor.fallback))
    #expect(snapshot.projection?.speakers.first { $0.id == "system:S2" }?.name == "Jim")
    // No other embedding is written: no voice file, no vector in the session.
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
    #expect(profileFilesContaining(profileVectorTexts([extractor.fallback]), in: session).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func enrollWithoutAudioKeepsNameOnly() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    lease.release()

    let extractor = ProfileFakeExtractor()
    let snapshot = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)
    #expect(snapshot.audioDeleted)
    #expect(snapshot.projection?.speakers.first { $0.id == "system:S1" }?.profileID != nil)
    #expect(extractor.requests.isEmpty)
    #expect(try store.load().profiles.map(\.samples.count) == [0])
    #expect(VoiceProfileService.audioDeletedNote.contains("audio was deleted"))

    // The in-process extractor refuses too.
    let direct = DiarizerVoiceSampleExtractor(diarizer: FakeDiarizer(outputs: [:]))
    await #expect(throws: HolosError.self) {
        _ = try await direct.turnEmbeddings(session: session, track: "system",
                                            turns: [TurnRef(id: "T1", start: 0.5, end: 3.4)])
    }
}

@Test(.timeLimit(.minutes(1)))
func linkWithoutRememberKeepsTheName() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, run) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)

    let database = try store.load()
    #expect(!database.rememberVoices)
    let jim = try #require(database.profiles.first)
    #expect(jim.displayName == "Jim" && jim.samples.isEmpty)
    #expect(extractor.requests.isEmpty)
    let edits = try SessionSpeakerStore.readEdits(session: session).edits.filter { $0.baseRunID == run.id }
    #expect(edits.map(\.action) == [.linkProfile(speakerID: "system:S1", profileID: jim.id),
                                    .rename(speakerID: "system:S1", name: "Jim")])
    #expect(Set(edits.compactMap(\.batchID)).count == 1 && edits.allSatisfy { $0.batchID != nil })
    #expect(VoiceProfileService.knownPeople(store: store).map(\.displayName) == ["Jim"])
    #expect(VoiceProfileService.profileNames(store: store) == [jim.id: "Jim"])
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).contains("Jim  "))
}

@Test(.timeLimit(.minutes(1)))
func linkWithLearnVoiceCreatesSample() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")]
    }
    let (session, _) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .existing(profileID: "JIM"),
        view: try SessionFixtures.view(session), learnVoice: true, extractor: extractor, store: store)
    let jim = try #require(try store.load().profiles.first)
    #expect(jim.samples.count == 1)
    #expect(jim.samples.first?.speakerIDs == ["system:S1"])
    #expect(extractor.requests == [.init(track: "system", turnIDs: ["T1", "T3"])])
    #expect(jim.lastUsedAt >= jim.createdAt)
}

@Test(.timeLimit(.minutes(1)))
func footerToggleControlsSampleWrites() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    let snapshot = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: false, extractor: extractor, store: store)
    #expect(snapshot.projection?.speakers.first { $0.id == "system:S1" }?.profileID != nil)
    #expect(try store.load().profiles.map(\.samples.count) == [0])
    #expect(extractor.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func refusedLinkRemovesTheNewPerson() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _) = try await profileSession(in: temp)
    let view = try SessionFixtures.view(session)
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Someone")], session: session)
    // The rename changed S1 since `view` was loaded, so the link (which renames too) is refused.
    await #expect(throws: HolosError.self) {
        _ = try await VoiceProfileService.link(session: session, speakerID: "system:S1", to: .new(name: "Jim"),
                                               view: view, learnVoice: false, extractor: nil, store: store)
    }
    #expect(try store.load().profiles.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func confirmAllIsOneEdit() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update {
        $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim"), SpeakerProfile(id: "MARIA", displayName: "Maria"),
                       SpeakerProfile(id: "SAM", displayName: "Sam")]
    }
    let (session, run) = try await profileSession(in: temp, speakers: ["S1", "S2", "S3"], duration: 30)
    let matches = [("system:S1", "JIM", "Jim"), ("system:S2", "MARIA", "Maria"), ("system:S3", "SAM", "Sam")].map {
        SpeakerMatch(speakerID: $0.0, profileID: $0.1, profileName: $0.2, distance: 0.2, tier: .possible)
    }
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: run.id, embeddingModel: profileModel,
                              thresholds: SpeakerRecognizer.defaultThresholds, matches: matches),
            session: session)
    }
    let view = try profileView(session, store: store)
    #expect(view.speakers.compactMap(\.suggestion).count == 3)

    let snapshot = try await VoiceProfileService.confirmAll(session: session, view: view, learnVoices: false,
                                                            extractor: nil, store: store)
    let edits = try SessionSpeakerStore.readEdits(session: session).edits
    #expect(edits.count == 6)
    #expect(Set(edits.compactMap(\.batchID)).count == 1)
    let confirmed = try #require(snapshot.projection)
    #expect(confirmed.speakers.map(\.profileID) == ["JIM", "MARIA", "SAM"])
    #expect(confirmed.speakers.map(\.name) == ["Jim", "Maria", "Sam"])
    #expect(confirmed.speakers.allSatisfy { $0.suggestion == nil })

    // One undo reverts all six lines.
    let undone = try SpeakerEditor.undoLast(view: confirmed, session: session, source: "app",
                                            regenerateExports: false)
    let reverted = try #require(undone.snapshot.projection)
    #expect(reverted.speakers.allSatisfy { $0.profileID == nil && $0.explicitName == nil })
    #expect(reverted.lastUndoableBatchID == nil)

    // Nothing left to confirm is refused.
    let none = try profileView(session, store: SpeakerProfileStore(directory: temp.url.appendingPathComponent("none")))
    await #expect(throws: HolosError.self) {
        _ = try await VoiceProfileService.confirmAll(session: session, view: none, learnVoices: false, extractor: nil,
                                                     store: store)
    }
}

@Test(.timeLimit(.minutes(1)))
func markSelfCreatesOneSelfProfile() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let first = try await profileSession(in: temp)
    let second = try await profileSession(in: temp)
    _ = try await VoiceProfileService.markSelf(session: first.session, speakerID: "system:S1",
                                               view: try SessionFixtures.view(first.session), learnVoice: false,
                                               extractor: nil, store: store)
    _ = try await VoiceProfileService.markSelf(session: second.session, speakerID: "system:S2",
                                               view: try SessionFixtures.view(second.session), learnVoice: false,
                                               extractor: nil, store: store)
    let people = try store.load().profiles
    let me = try #require(people.first)
    #expect(people.count == 1)
    #expect(me.isSelf)
    #expect(me.displayName == VoiceProfileService.selfName)
    #expect(try SessionFixtures.view(first.session).speakers.first { $0.id == "system:S1" }?.profileID == me.id)
    #expect(try SessionFixtures.view(second.session).speakers.first { $0.id == "system:S2" }?.profileID == me.id)
}

@Test(.timeLimit(.minutes(1)))
func markSelfHonoursLearnVoice() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    _ = try await VoiceProfileService.markSelf(session: session, speakerID: "system:S1",
                                               view: try SessionFixtures.view(session), learnVoice: false,
                                               extractor: extractor, store: store)
    #expect(try store.load().profiles.map(\.samples.count) == [0])
    #expect(extractor.requests.isEmpty)

    // Marked again with the box checked: the link is already there; the voice is learned.
    _ = try await VoiceProfileService.markSelf(session: session, speakerID: "system:S1",
                                               view: try SessionFixtures.view(session), learnVoice: true,
                                               extractor: extractor, store: store)
    #expect(try store.load().profiles.map(\.samples.count) == [1])
    #expect(extractor.requests.map(\.turnIDs) == [["T1", "T3"]])
    #expect(try SessionSpeakerStore.readEdits(session: session).edits.count == 2, "The second call adds no edit.")
}

// MARK: - Keeping samples in step

@Test(.timeLimit(.minutes(1)))
func reassignAfterEnrollmentRecomputesSample() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let t1 = profileUnit([1, 0.3, 0, 0, 0, 0, 0, 0])
    let t3 = profileUnit([1, -0.3, 0, 0, 0, 0, 0, 0])
    let extractor = ProfileFakeExtractor(vectors: ["T1": t1, "T3": t3])
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)
    let before = try #require(try store.load().profiles.first?.samples.first)

    // A rename changes no sample input.
    let renamed = try SpeakerEditor.apply([.rename(speakerID: "system:S2", name: "Maria")],
                                          view: try SessionFixtures.view(session), session: session, source: "cli",
                                          regenerateExports: false, profiles: store)
    #expect(!renamed.needsSampleRefresh)

    let result = try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T3"], to: "system:S2")],
                                         view: try SessionFixtures.view(session), session: session, source: "cli",
                                         regenerateExports: false, profiles: store)
    #expect(result.needsSampleRefresh)
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    let after = try #require(try store.load().profiles.first?.samples.first)
    #expect(after.id == before.id)
    #expect(after.addedAt == before.addedAt)
    #expect(profileClose(after.embedding.values, t1))
    #expect(after.speechSeconds < before.speechSeconds)
    #expect(extractor.requests.last?.turnIDs == ["T1"])

    // Up to date: another refresh asks the extractor nothing.
    let calls = extractor.requests.count
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    #expect(extractor.requests.count == calls)

    // Unlinking the speaker (rejecting the person) removes the sample.
    let jimID = try #require(try store.load().profiles.first?.id)
    _ = try VoiceProfileService.reject(session: session, speakerID: "system:S1", profileID: jimID,
                                       view: try SessionFixtures.view(session))
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    #expect(try store.load().profiles.first?.samples.isEmpty == true)
    #expect(try store.load().profiles.first?.embeddingModel == nil)
}

@Test(.timeLimit(.minutes(1)))
func rememberOffRemovesAnAffectedSampleInsteadOfRelearning() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)
    try VoiceProfileService.setRemember(false, forgetExisting: false, store: store, sessionsRoot: temp.url)
    #expect(try store.load().sampleCount == 1, "Turning Remember voices off keeps samples unless asked.")
    try SpeakerEditor.apply([.excludeFromEnrollment(turnIDs: ["T3"])], view: try SessionFixtures.view(session),
                            session: session, source: "cli", regenerateExports: false)
    let calls = extractor.requests.count
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    #expect(extractor.requests.count == calls, "Nothing is extracted while Remember voices is off.")
    #expect(try store.load().sampleCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func staleRefreshDoesNotOverwriteNewerSample() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let vectors = ["T1": profileUnit([1, 0.1, 0, 0, 0, 0, 0, 0]), "T2": profileUnit([1, 0, 0.1, 0, 0, 0, 0, 0]),
                   "T3": profileUnit([1, 0, 0, 0.1, 0, 0, 0, 0]), "T4": profileUnit([1, 0, 0, 0, 0.1, 0, 0, 0])]
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: ProfileFakeExtractor(vectors: vectors), store: store)
    let jimID = try #require(try store.load().profiles.first?.id)

    // S2 is Jim too: the sample's inputs change (all four turns).
    try SessionFixtures.appendEdits([.linkProfile(speakerID: "system:S2", profileID: jimID)], session: session)

    // Extraction A starts from that state and waits.
    let entered = SharedValue(false)
    let gate = SharedValue(false)
    let slow = ProfileFakeExtractor(vectors: vectors) { call in
        guard call == 1 else { return }
        entered.set(true)
        while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
    }
    let first = Task { try await VoiceProfileService.refreshSamples(session: session, extractor: slow, store: store) }
    #expect(await profileEventually { entered.value })
    #expect(slow.requests.first?.turnIDs == ["T1", "T2", "T3", "T4"])

    // An edit leaves T4 out; extraction B runs on the new labels and finishes first.
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: ["T4"])], session: session)
    let fast = ProfileFakeExtractor(vectors: vectors)
    try await VoiceProfileService.refreshSamples(session: session, extractor: fast, store: store)
    #expect(fast.requests.map(\.turnIDs) == [["T1", "T2", "T3"]])
    let newer = try #require(try store.load().profiles.first?.samples.first)

    // A finishes last: its result is discarded; the retry finds the sample up to date.
    gate.set(true)
    try await first.value
    #expect(slow.requests.count == 1)
    let final = try #require(try store.load().profiles.first?.samples.first)
    #expect(final == newer)
    let expected = profileUnit((0..<8).map { index in
        ["T1", "T2", "T3"].reduce(Float(0)) { $0 + vectors[$1]![index] }
    })
    #expect(profileClose(final.embedding.values, expected, tolerance: 1e-4))
    #expect(final.speakerIDs == ["system:S1", "system:S2"])
}

@Test(.timeLimit(.minutes(1)))
func refreshGivesUpAfterThreeChanges() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: ProfileFakeExtractor(), store: store)
    let original = try #require(try store.load().profiles.first?.samples.first)
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: ["T3"])], session: session)

    // Every extraction sees the labels change under it.
    let busy = ProfileFakeExtractor { call in
        try SessionFixtures.appendEdits([.rename(speakerID: "system:S2", name: "Name \(call)")], session: session)
    }
    // Giving up is reported, so a caller never says the voice was learned or is up to date.
    do {
        try await VoiceProfileService.refreshSamples(session: session, extractor: busy, store: store)
        Issue.record("Giving up must throw.")
    } catch let HolosError.unavailable(message) {
        #expect(message == VoiceProfileService.labelsKeptChanging)
    }
    #expect(busy.requests.count == VoiceProfileService.sampleAttempts)
    #expect(try store.load().profiles.first?.samples.first == original, "The existing sample is left as it was.")
}

@Test func earlierRunIsToldFromTheGeneration() {
    func sample(_ generation: String?) -> VoiceprintSample {
        VoiceprintSample(sessionID: "S", sessionName: "x", speakerIDs: [], speechSeconds: 30,
                         embedding: FloatVector([1, 0]), condition: .room, weak: false, generation: generation)
    }
    #expect(VoiceProfileService.builtFromEarlierRun(sample("OLD:20"), headRunID: "RUN"))
    #expect(!VoiceProfileService.builtFromEarlierRun(sample("RUN:20"), headRunID: "RUN"))
    #expect(!VoiceProfileService.builtFromEarlierRun(sample(nil), headRunID: "RUN"))
}

@Test(.timeLimit(.minutes(1)))
func forgetDuringRefreshKeepsTheSampleForgotten() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: ProfileFakeExtractor(), store: store)
    let sample = try #require(try store.load().profiles.first?.samples.first)
    // The sample's inputs change, so a refresh recomputes it.
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: ["T3"])], session: session)

    let entered = SharedValue(false)
    let gate = SharedValue(false)
    let slow = ProfileFakeExtractor { _ in
        entered.set(true)
        while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
    }
    let refresh = Task { try await VoiceProfileService.refreshSamples(session: session, extractor: slow, store: store) }
    #expect(await profileEventually { entered.value })

    // The user forgets the sample while it is being recomputed; the refresh then finishes.
    try VoiceProfileService.forget(sampleID: sample.id, store: store, sessionsRoot: temp.url)
    gate.set(true)
    try await refresh.value
    #expect(try store.load().sampleCount == 0, "A refresh never brings a forgotten sample back.")
    #expect(try store.load().profiles.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func refreshAfterAFailedSaveStillRecomputes() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let t1 = profileUnit([1, 0.3, 0, 0, 0, 0, 0, 0])
    let t3 = profileUnit([1, -0.3, 0, 0, 0, 0, 0, 0])
    let extractor = ProfileFakeExtractor(vectors: ["T1": t1, "T3": t3])
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)
    // T3 goes to S2 and the save then "fails" (the exports could not be rewritten): the sample is still updated,
    // and the original error is what the caller sees.
    try SessionFixtures.appendEdits([.reassignTurns(turnIDs: ["T3"], to: "system:S2")], session: session)
    do {
        try await VoiceProfileService.refreshSamples(afterSaving: HolosError.incomplete("Exports failed."),
                                                     session: session, extractor: extractor, store: store)
    } catch let HolosError.incomplete(message) {
        #expect(message == "Exports failed.")
    }
    let after = try #require(try store.load().profiles.first?.samples.first)
    #expect(profileClose(after.embedding.values, t1))
    #expect(extractor.requests.last?.turnIDs == ["T1"])
}

@Test(.timeLimit(.minutes(1)))
func sampleFromAnEarlierRunIsKeptWhenItCannotBeRelearned() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _) = try await profileSession(in: temp)
    // Jim kept a sample from this meeting's earlier labels (another run) with Remember voices off ("Keep").
    var old = VoiceprintSample(sessionID: try profileManifestID(session), sessionName: "Fixture meeting",
                               speakerIDs: ["system:S9"], speechSeconds: 30, embedding: FloatVector(profileAxis(0)),
                               condition: .call, weak: false, generation: "OLDRUN:120")
    old.inputDigest = "old"
    try store.update {
        $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim", embeddingModel: profileModel, samples: [old])]
    }
    let extractor = ProfileFakeExtractor()
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    try SpeakerEditor.apply([.linkProfile(speakerID: "system:S1", profileID: "JIM")],
                            view: try SessionFixtures.view(session), session: session, source: "cli",
                            regenerateExports: false)
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    let kept = try store.load().profiles.first?.samples ?? []
    #expect(kept.map(\.id) == [old.id], "Kept: the earlier run's turns cannot change.")
    #expect(kept.first?.speakerIDs == ["system:S9"] && kept.first?.inputDigest == "old")
    #expect(extractor.requests.isEmpty)

    // With Remember voices on, the new labels replace it.
    try store.update { $0.rememberVoices = true }
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    let replaced = try #require(try store.load().profiles.first?.samples.first)
    #expect(replaced.id == old.id)
    #expect(replaced.speakerIDs == ["system:S1"])
}

@Test(.timeLimit(.minutes(1)))
func generationFollowsHeadAndJournal() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let (session, run) = try await profileSession(in: temp)
    let before = try SessionSpeakerStore.generation(session: session)
    #expect(before == "\(run.id):0")
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Jim")], session: session)
    let after = try #require(try SessionSpeakerStore.generation(session: session))
    #expect(after != before && after.hasPrefix(run.id + ":"))
}

// MARK: - Merging people

@Test(.timeLimit(.minutes(1)))
func mergedPersonKeepsTheirMovedSample() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jimmy"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: extractor, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "JIM", displayName: "Jim")) }
    let jimmy = try #require(try store.load().profiles.first { $0.displayName == "Jimmy" })

    try VoiceProfileService.merge(profileID: jimmy.id, into: "JIM", store: store)
    let merged = try store.load().profiles
    #expect(merged.map(\.id) == ["JIM"])
    #expect(merged.first?.samples == jimmy.samples)
    #expect(merged.first?.embeddingModel == profileModel)

    // The meeting still links S1 to the merged-away person; the moved sample stays in step (not removed).
    let calls = extractor.requests.count
    try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
    #expect(try store.load().profiles.first?.samples == jimmy.samples)
    #expect(extractor.requests.count == calls)

    // Different embedding models are refused.
    try store.update {
        $0.profiles.append(SpeakerProfile(id: "OTHER", displayName: "Other",
                                          embeddingModel: EmbeddingModelID(id: "other", revision: "2"),
                                          samples: [VoiceprintSample(sessionID: UUID().uuidString, sessionName: "x",
                                                                     speakerIDs: [], speechSeconds: 30,
                                                                     embedding: FloatVector([1, 0]), condition: .room,
                                                                     weak: false)]))
    }
    #expect(throws: HolosError.self) { try VoiceProfileService.merge(profileID: "OTHER", into: "JIM", store: store) }
}

@Test(.timeLimit(.minutes(1)))
func renameAndSuggestionsChangeThePerson() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")] }
    try VoiceProfileService.rename(profileID: "JIM", to: "  James \n Smith ", store: store)
    try VoiceProfileService.setSuggestions(false, profileID: "JIM", store: store)
    let jim = try #require(try store.load().profiles.first)
    #expect(jim.displayName == "James Smith")
    #expect(!jim.recognitionEnabled)
    #expect(throws: HolosError.self) { try VoiceProfileService.rename(profileID: "JIM", to: "  ", store: store) }
    #expect(throws: HolosError.self) { try VoiceProfileService.rename(profileID: "NOBODY", to: "X", store: store) }
}

// MARK: - Forgetting

/// A processed session with the evaluation voice file, mic:S1 linked to a new person "Jim" with a sample, and a
/// recognition result that suggests Jim for mic:S2.
private func profileForgetFixture(_ temp: TemporaryDirectory,
                                  store: SpeakerProfileStore) async throws -> (session: URL, runID: String, jim: String) {
    try store.update { $0.rememberVoices = true }
    let (session, record) = try await profileProcessedSession(in: temp, store: nil, forceVoiceData: true)
    let runID = try #require(record.runID)
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "mic:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: ProfileFakeExtractor(), store: store)
    let jim = try #require(try store.load().profiles.first?.id)
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: runID, embeddingModel: profileModel,
                              thresholds: SpeakerRecognizer.defaultThresholds,
                              matches: [SpeakerMatch(speakerID: "mic:S2", profileID: jim, profileName: "Jim",
                                                     distance: 0.3, tier: .possible)]),
            session: session)
    }
    return (session, runID, jim)
}

@Test(.timeLimit(.minutes(1)))
func forgetPersonRemovesSamplesAndVoiceEntries() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    let voiceBefore = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(Set(voiceBefore.centroids.keys) == ["mic:S1", "mic:S2"])
    try FileManager.default.removeItem(at: SessionPaths.export("md", in: session))

    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)

    #expect(try store.load().profiles.isEmpty)
    let voice = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(Array(voice.centroids.keys) == ["mic:S2"])
    #expect(voice.turnEmbeddings.map(\.turnID).sorted() == ["T2", "T4"])
    let recognition = try #require(try SessionSpeakerStore.readRecognition(runID: runID, session: session))
    #expect(recognition.matches.isEmpty)
    // The meeting keeps the name (its own rename), and its exports were rewritten.
    #expect(try SessionFixtures.view(session).speakers.first { $0.id == "mic:S1" }?.name == "Jim")
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).contains("**Jim**"))
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetAllRemovesVoiceFilesKeepsNames() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (first, _, _) = try await profileForgetFixture(temp, store: store)
    let (second, _) = try await profileProcessedSession(in: temp, store: nil, forceVoiceData: true)
    #expect(SessionFixtures.exists(SessionPaths.voiceDirectory(second)))

    try VoiceProfileService.forgetAll(store: store, sessionsRoot: temp.url)

    for session in [first, second] {
        #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
        #expect(!SessionFixtures.exists(session.appendingPathComponent("speakers/recognition")))
    }
    let people = try store.load().profiles
    #expect(people.map(\.displayName) == ["Jim"])
    #expect(people.allSatisfy { $0.samples.isEmpty && $0.embeddingModel == nil })
    #expect(try SessionFixtures.view(first).speakers.first { $0.id == "mic:S1" }?.name == "Jim")
}

@Test(.timeLimit(.minutes(1)))
func forgetSessionRemovesItsSamples() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let a = UUID().uuidString
    let b = UUID().uuidString
    var jim = profilePerson("JIM", "Jim", vector: profileAxis(0), session: a)
    jim.samples += profilePerson("X", "X", vector: profileAxis(1), session: b).samples
    let maria = profilePerson("MARIA", "Maria", vector: profileAxis(2), session: a)
    try store.update { $0.profiles = [jim, maria] }

    try VoiceProfileService.forget(sessionID: a, store: store)

    let people = try store.load().profiles
    #expect(people.first { $0.id == "JIM" }?.samples.map(\.sessionID) == [b])
    #expect(people.first { $0.id == "MARIA" }?.samples.isEmpty == true)
    #expect(people.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func forgetSampleRemovesOnlyThatSample() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    let sample = try #require(try store.load().profiles.first?.samples.first)
    try VoiceProfileService.forget(sampleID: sample.id, store: store, sessionsRoot: temp.url)
    #expect(try store.load().profiles.map(\.id) == [jim], "The person stays.")
    #expect(try store.load().sampleCount == 0)
    let voice = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(Array(voice.centroids.keys) == ["mic:S2"])
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func rememberOffWithForget() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, _) = try await profileForgetFixture(temp, store: store)
    try VoiceProfileService.setRemember(false, forgetExisting: true, store: store, sessionsRoot: temp.url)
    let database = try store.load()
    #expect(!database.rememberVoices)
    #expect(database.sampleCount == 0)
    #expect(database.profiles.map(\.displayName) == ["Jim"])
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
}

/// Replaces `url` with bytes that are not JSON.
private func profileDamage(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
    try Data("not json".utf8).write(to: url)
}

@Test(.timeLimit(.minutes(1)))
func forgetFinishesOverUnreadableRecognitionAndVoiceFiles() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)

    // A person: an unreadable recognition file is deleted (it may name them), and the forget finishes.
    let (first, firstRun, jim) = try await profileForgetFixture(temp, store: store)
    try profileDamage(SessionPaths.recognition(firstRun, in: first))
    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    #expect(try store.pendingForgets().isEmpty)
    #expect(!SessionFixtures.exists(first.appendingPathComponent("speakers/recognition")))
    #expect(try SessionSpeakerStore.readVoiceData(runID: firstRun, session: first)?.centroids["mic:S1"] == nil)

    // A sample: an unreadable voice file is deleted.
    let (second, secondRun, _) = try await profileForgetFixture(temp, store: store)
    try profileDamage(SessionPaths.voiceData(secondRun, in: second))
    let secondID = try profileManifestID(second)
    let sample = try #require(try store.load().profiles.flatMap(\.samples).first { $0.sessionID == secondID })
    try VoiceProfileService.forget(sampleID: sample.id, store: store, sessionsRoot: temp.url)
    #expect(try store.pendingForgets().isEmpty)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(second)))

    // Everything: unreadable files are deleted without being read first.
    let (third, thirdRun, _) = try await profileForgetFixture(temp, store: store)
    try profileDamage(SessionPaths.recognition(thirdRun, in: third))
    try profileDamage(SessionPaths.voiceData(thirdRun, in: third))
    try VoiceProfileService.forgetAll(store: store, sessionsRoot: temp.url)
    #expect(try store.pendingForgets().isEmpty)
    for session in [first, second, third] {
        #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
        #expect(!SessionFixtures.exists(session.appendingPathComponent("speakers/recognition")))
    }
}

@Test(.timeLimit(.minutes(1)))
func rememberOffWithForgetTurnsOffInTheSameWrite() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, _) = try await profileForgetFixture(temp, store: store)
    struct Crash: Error {}
    #expect(throws: Crash.self) {
        try VoiceProfileService.$afterForgetStoreUpdate.withValue({ throw Crash() }) {
            try VoiceProfileService.setRemember(false, forgetExisting: true, store: store, sessionsRoot: temp.url)
        }
    }
    // The setting and the samples changed together, and the tombstone is there to finish the rest.
    #expect(try !store.load().rememberVoices)
    #expect(try store.load().sampleCount == 0)
    #expect(try store.pendingForgets().count == 1)

    // A resumed forget never turns the setting off again.
    try VoiceProfileService.setRemember(true, forgetExisting: false, store: store, sessionsRoot: temp.url)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    #expect(try store.load().rememberVoices)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
}

@Test(.timeLimit(.minutes(1)))
func forgetResumesAfterCrashBetweenStoreAndSessions() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)

    struct Crash: Error {}
    #expect(throws: Crash.self) {
        try VoiceProfileService.$afterForgetStoreUpdate.withValue({ throw Crash() }) {
            try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
        }
    }
    // The store is updated; the meeting still holds references; the tombstone is pending.
    #expect(try store.load().profiles.isEmpty)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.count == 1)
    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session)?.centroids["mic:S1"] != nil)
    #expect(try store.pendingForgets().count == 1)

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.isEmpty == true)
    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session)?.centroids["mic:S1"] == nil)
    #expect(try store.pendingForgets().isEmpty)
    #expect(!SessionFixtures.exists(store.forgetJournalURL), "A finished journal is compacted away.")
}

@Test(.timeLimit(.minutes(1)))
func forgetJournalReplayIsIdempotent() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, jim) = try await profileForgetFixture(temp, store: store)
    struct Crash: Error {}
    #expect(throws: Crash.self) {
        try VoiceProfileService.$afterForgetStoreUpdate.withValue({ throw Crash() }) {
            try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
        }
    }
    let record = try #require(try store.pendingForgets().first)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    let sessionFiles = SessionFixtures.files(in: session)
    let people = try store.load()

    // Resuming again, and replaying the same tombstone, change nothing.
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    try VoiceProfileService.perform(record, store: store, sessionsRoot: temp.url)
    #expect(SessionFixtures.files(in: session) == sessionFiles)
    #expect(try store.load() == people)
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func rememberOffForgetsSamplesLearnedAfterTheyWereListed() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    _ = try await profileForgetFixture(temp, store: store)
    // The tombstone listed no sample: one was learned between the listing and the store write.
    let stale = ForgetRecord(kind: .all, sampleIDs: [])
    try store.appendForgetRecord(stale)
    try VoiceProfileService.perform(stale, store: store, sessionsRoot: temp.url, turnRememberOff: true, initial: true)
    #expect(try !store.load().rememberVoices)
    #expect(try store.load().sampleCount == 0)
    #expect(try store.pendingForgets().isEmpty)

    // A resumed `.all` removes only the samples it lists: the user may have turned remembering back on since.
    try store.update {
        $0.rememberVoices = true
        $0.profiles.append(profilePerson("MARIA", "Maria", vector: profileAxis(2)))
    }
    let resumed = ForgetRecord(kind: .all, sampleIDs: [])
    try store.appendForgetRecord(resumed)
    try VoiceProfileService.perform(resumed, store: store, sessionsRoot: temp.url)
    #expect(try store.load().sampleCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func forgetDeletesVoiceDataWhenTheEditJournalHasUnreadableLines() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)

    // A complete line from a newer Holos: it may link the person, so the voice data is deleted.
    let (first, _, jim) = try await profileForgetFixture(temp, store: store)
    let newer = try FileHandle(forWritingTo: SessionPaths.edits(first))
    try newer.seekToEnd()
    try newer.write(contentsOf: Data(#"{"schemaVersion": 99, "id": "FUTURE"}"#.utf8 + [0x0A]))
    try newer.close()
    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(first)))
    #expect(try store.pendingForgets().isEmpty)

    // A torn last line, for one sample.
    let (second, _, _) = try await profileForgetFixture(temp, store: store)
    let torn = try FileHandle(forWritingTo: SessionPaths.edits(second))
    try torn.seekToEnd()
    try torn.write(contentsOf: Data(#"{"schemaVersion": 1, "id": "#.utf8))
    try torn.close()
    let secondID = try profileManifestID(second)
    let sample = try #require(try store.load().profiles.flatMap(\.samples).first { $0.sessionID == secondID })
    try VoiceProfileService.forget(sampleID: sample.id, store: store, sessionsRoot: temp.url)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(second)))
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetCleansMeetingsWhoseManifestCannotBeRead() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)

    // A damaged manifest: the speaker lock is taken and the voice data and recognition results are deleted.
    let (first, _, jim) = try await profileForgetFixture(temp, store: store)
    try profileDamage(SessionPaths.manifest(first))
    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(first)))
    #expect(!SessionFixtures.exists(first.appendingPathComponent("speakers/recognition")))
    #expect(try store.pendingForgets().isEmpty)

    // A missing manifest, for everything.
    let (second, _, _) = try await profileForgetFixture(temp, store: store)
    try FileManager.default.removeItem(at: SessionPaths.manifest(second))
    try VoiceProfileService.forgetAll(store: store, sessionsRoot: temp.url)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(second)))
    #expect(!SessionFixtures.exists(second.appendingPathComponent("speakers/recognition")))
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetStaysPendingWhenTheMeetingsFolderCannotBeListed() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0))] }
    let root = temp.url.appendingPathComponent("Meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(chmod(root.path, 0) == 0)
    defer { chmod(root.path, 0o700) }

    #expect(throws: HolosError.self) {
        try VoiceProfileService.forget(profileID: "JIM", store: store, sessionsRoot: root)
    }
    #expect(try store.load().profiles.isEmpty, "The store was updated first.")
    #expect(try store.pendingForgets().count == 1, "The meetings were not checked, so the forget is not done.")

    #expect(chmod(root.path, 0o700) == 0)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: root)
    #expect(try store.pendingForgets().isEmpty)

    // A folder that does not exist holds no meetings.
    try store.update { $0.profiles = [profilePerson("MARIA", "Maria", vector: profileAxis(1))] }
    try VoiceProfileService.forget(profileID: "MARIA", store: store,
                                   sessionsRoot: temp.url.appendingPathComponent("Missing", isDirectory: true))
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetPersonRemovesEntriesOfPeopleMergedIntoThem() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    // Jim is merged into Maria; the meeting's link still names Jim.
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store)

    try VoiceProfileService.forget(profileID: "MARIA", store: store, sessionsRoot: temp.url)

    let voice = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(Array(voice.centroids.keys) == ["mic:S2"])
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.isEmpty == true)
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetDeletesVoiceFoldersWithUnexpectedFiles() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, jim) = try await profileForgetFixture(temp, store: store)
    // A temporary file a crash left mid-write may hold a copy of the voice data.
    try Data("partial".utf8).write(to: SessionPaths.voiceDirectory(session).appendingPathComponent(".LEFT.tmp"))
    try Data("partial".utf8).write(
        to: session.appendingPathComponent("speakers/recognition/.LEFT.tmp", isDirectory: false))
    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
    #expect(!SessionFixtures.exists(session.appendingPathComponent("speakers/recognition")))
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func recognitionDropsPeopleWhoseSuggestionsWereTurnedOffMeanwhile() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, record) = try await profileProcessedSession(in: temp, store: nil, forceVoiceData: true)
    let runID = try #require(record.runID)
    let run = try SessionSpeakerStore.readRun(id: runID, session: session)
    let voiceData = try SessionSpeakerStore.readVoiceData(runID: runID, session: session)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0)),
                       profilePerson("MARIA", "Maria", vector: profileAxis(1))]
    }

    guard case .recognized(let before) = RecognizeStage.run(run, voiceData: voiceData, session: session,
                                                           store: store) else {
        Issue.record("Expected a recognition result")
        return
    }
    #expect(before.matches.map(\.profileID).sorted() == ["JIM", "MARIA"])

    // Jim's suggestions are turned off, and Maria's samples change model, after the comparison.
    let outcome = RecognizeStage.$beforeSaving.withValue({
        try VoiceProfileService.setSuggestions(false, profileID: "JIM", store: store)
        try store.update { database in
            let index = try #require(database.profiles.firstIndex { $0.id == "MARIA" })
            database.profiles[index].embeddingModel = EmbeddingModelID(id: "other", revision: "2")
        }
    }) {
        RecognizeStage.run(run, voiceData: voiceData, session: session, store: store)
    }
    guard case .recognized(let result) = outcome else {
        Issue.record("Expected a recognition result, got \(outcome)")
        return
    }
    #expect(result.matches.isEmpty)
    #expect(result.mergeSuggestions.isEmpty)
    #expect(result.skippedProfiles == ["MARIA"])
    let saved = try #require(try SessionSpeakerStore.readRecognition(runID: runID, session: session))
    #expect(saved.matches.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func recognitionIsComparedAgainWithTheSamplesPresentWhenSaved() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let root = temp.url
    let store = profileStore(temp)
    let (session, record) = try await profileProcessedSession(in: temp, store: nil, forceVoiceData: true)
    let runID = try #require(record.runID)
    let run = try SessionSpeakerStore.readRun(id: runID, session: session)
    let voiceData = try SessionSpeakerStore.readVoiceData(runID: runID, session: session)
    // Jim has two samples: one matches mic:S1 (axis 0), the other matches nobody.
    var jim = profilePerson("JIM", "Jim", vector: profileAxis(0))
    jim.samples += profilePerson("X", "X", vector: profileAxis(5)).samples
    let matching = jim.samples[0].id
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [jim]
    }

    // The matching sample is forgotten after the first read: Jim stays eligible (he has another sample), but the
    // match rested on the forgotten sample, so it is not saved.
    let forgotten = RecognizeStage.$beforeSaving.withValue({
        try VoiceProfileService.forget(sampleID: matching, store: store, sessionsRoot: root)
    }) {
        RecognizeStage.run(run, voiceData: voiceData, session: session, store: store)
    }
    guard case .recognized(let result) = forgotten else {
        Issue.record("Expected a recognition result, got \(forgotten)")
        return
    }
    #expect(result.matches.isEmpty)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.isEmpty == true)

    // A person learned meanwhile is compared too.
    let learned = RecognizeStage.$beforeSaving.withValue({
        try store.update { $0.profiles.append(profilePerson("MARIA", "Maria", vector: profileAxis(1))) }
    }) {
        RecognizeStage.run(run, voiceData: voiceData, session: session, store: store)
    }
    guard case .recognized(let second) = learned else {
        Issue.record("Expected a recognition result, got \(learned)")
        return
    }
    #expect(second.matches.map(\.profileID) == ["MARIA"])
}

@Test(.timeLimit(.minutes(1)))
func refreshRedoesItsPlanWhenTheStoreChangedMeanwhile() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let root = temp.url
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileSession(in: temp)
    _ = try await VoiceProfileService.link(
        session: session, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(session),
        learnVoice: true, extractor: ProfileFakeExtractor(), store: store)
    // T3 is left out, so the sample (which holds T3) must be recomputed or removed.
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: ["T3"])], session: session)

    // Remember voices is turned off (samples kept) while the sample is recomputed. The recomputed sample may not be
    // saved, and the stale one must not stay either: the plan is made again from the store as it now is.
    let turnedOff = ProfileFakeExtractor { _ in
        try VoiceProfileService.setRemember(false, forgetExisting: false, store: store, sessionsRoot: root)
    }
    try await VoiceProfileService.refreshSamples(session: session, extractor: turnedOff, store: store)
    #expect(turnedOff.requests.count == 1, "The second attempt removes the sample without extracting.")
    #expect(try store.load().sampleCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func forgetSessionRemovesSamplesLearnedAfterTheListing() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let a = UUID().uuidString
    let b = UUID().uuidString
    try store.update {
        $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0), session: a),
                       profilePerson("MARIA", "Maria", vector: profileAxis(1), session: b)]
    }
    // The tombstone listed no sample: Jim's was learned from meeting A between the listing and the store write.
    let stale = ForgetRecord(kind: .session, sampleIDs: [], sessionIDs: [a])
    try store.appendForgetRecord(stale)
    #expect(try VoiceProfileService.perform(stale, store: store, sessionsRoot: temp.url, initial: true) == 1)
    #expect(try store.load().profiles.first { $0.id == "JIM" }?.samples.isEmpty == true)
    #expect(try store.load().profiles.first { $0.id == "MARIA" }?.samples.count == 1)
    #expect(try store.pendingForgets().isEmpty)

    // A resumed `.session` removes only the samples it lists: meeting A may have been linked again since.
    try store.update { database in
        let index = try #require(database.profiles.firstIndex { $0.id == "JIM" })
        database.profiles[index] = profilePerson("JIM", "Jim", vector: profileAxis(0), session: a)
    }
    let resumed = ForgetRecord(kind: .session, sampleIDs: [], sessionIDs: [a])
    try store.appendForgetRecord(resumed)
    #expect(try VoiceProfileService.perform(resumed, store: store, sessionsRoot: temp.url) == 0)
    #expect(try store.load().sampleCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func forgetPersonRemovesEveryReferenceInRecognition() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "OTHER", displayName: "Other")) }
    // This result names Jim only as skipped (his samples were of another model when it was made).
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: runID, embeddingModel: profileModel,
                              thresholds: SpeakerRecognizer.defaultThresholds, matches: [],
                              skippedProfiles: [jim, "OTHER"]),
            session: session)
    }
    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    let result = try #require(try SessionSpeakerStore.readRecognition(runID: runID, session: session))
    #expect(result.skippedProfiles == ["OTHER"])
    #expect(try store.pendingForgets().isEmpty)

    // The one helper every scrub uses covers each field that holds a person's ID.
    var all = RecognitionResult(
        runID: runID, embeddingModel: profileModel, thresholds: SpeakerRecognizer.defaultThresholds,
        matches: [SpeakerMatch(speakerID: "mic:S1", profileID: "JIM", profileName: "Jim", distance: 0.2,
                               tier: .possible)],
        mergeSuggestions: [MergeSuggestion(speakerIDs: ["mic:S1", "mic:S2"], profileID: "JIM")],
        skippedProfiles: ["JIM", "OTHER"])
    #expect(all.removeProfiles { $0 == "JIM" })
    #expect(all.matches.isEmpty && all.mergeSuggestions.isEmpty && all.skippedProfiles == ["OTHER"])
    #expect(!all.removeProfiles { $0 == "JIM" }, "Nothing left to remove.")
}

@Test(.timeLimit(.minutes(1)))
func noVoiceIsLearnedOrSuggestedWhenEditsCannotAllBeRead() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [SpeakerProfile(id: "MARIA", displayName: "Maria")]
    }

    // A torn last line: the sample Jim has from this meeting is neither recomputed nor removed, and the caller is
    // told why.
    let (first, _) = try await profileSession(in: temp)
    let extractor = ProfileFakeExtractor()
    _ = try await VoiceProfileService.link(
        session: first, speakerID: "system:S1", to: .new(name: "Jim"), view: try SessionFixtures.view(first),
        learnVoice: true, extractor: extractor, store: store)
    let sample = try #require(try store.load().profiles.flatMap(\.samples).first)
    let torn = try FileHandle(forWritingTo: SessionPaths.edits(first))
    try torn.seekToEnd()
    try torn.write(contentsOf: Data(#"{"schemaVersion": 1, "id": "#.utf8))
    try torn.close()
    do {
        try await VoiceProfileService.refreshSamples(session: first, extractor: extractor, store: store)
        Issue.record("A refresh over an incomplete journal must say so.")
    } catch let HolosError.unavailable(message) {
        #expect(message == VoiceProfileService.incompleteEdits)
    }
    #expect(try store.load().profiles.flatMap(\.samples) == [sample])
    #expect(extractor.requests.count == 1)

    // A line from a newer Holos (it may reject or move a speaker): the suggestion is not shown, confirming it is
    // refused, and no voice is learned.
    let (second, run) = try await profileSession(in: temp)
    try SessionFixtures.appendEdits([.linkProfile(speakerID: "system:S1", profileID: "MARIA")], session: second)
    try SessionArchive.withSpeakerLock(at: second) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: run.id, embeddingModel: profileModel,
                              thresholds: SpeakerRecognizer.defaultThresholds,
                              matches: [SpeakerMatch(speakerID: "system:S2", profileID: "MARIA", profileName: "Maria",
                                                     distance: 0.2, tier: .possible)]),
            session: second)
    }
    let before = try profileView(second, store: store)
    #expect(before.speakers.first { $0.id == "system:S2" }?.suggestion != nil)
    let newer = try FileHandle(forWritingTo: SessionPaths.edits(second))
    try newer.seekToEnd()
    try newer.write(contentsOf: Data(#"{"schemaVersion": 99, "id": "FUTURE"}"#.utf8 + [0x0A]))
    try newer.close()

    let after = try SpeakerSessionSnapshot.load(session: second,
                                                profileNames: VoiceProfileService.profileNames(store: store))
    #expect(after.recognition == nil)
    let s2 = try #require(after.projection?.speakers.first { $0.id == "system:S2" })
    #expect(s2.suggestion == nil && s2.profileID == nil)
    do {
        _ = try await VoiceProfileService.confirmAll(session: second, view: before, learnVoices: false, extractor: nil,
                                                     store: store)
        Issue.record("Confirming suggestions over an incomplete journal must be refused.")
    } catch let HolosError.unavailable(message) {
        #expect(message == VoiceProfileService.incompleteEdits)
    }
    let learner = ProfileFakeExtractor()
    do {
        try await VoiceProfileService.syncSamples(session: second, extractor: learner, store: store,
                                                  enroll: ["MARIA"])
        Issue.record("Learning a voice over an incomplete journal must be refused.")
    } catch let HolosError.unavailable(message) {
        #expect(message == VoiceProfileService.incompleteEdits)
    }
    #expect(learner.requests.isEmpty)
    #expect(try store.load().profiles.first { $0.id == "MARIA" }?.samples.isEmpty == true)
}

@Test(.timeLimit(.minutes(1)))
func applyCalibrationStoresItsModelAndRefusesMixedModels() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    func person(_ id: String, _ samples: [(String, [Float])]) -> SpeakerProfile {
        SpeakerProfile(id: id, displayName: id, embeddingModel: profileModel, samples: samples.map { session, vector in
            VoiceprintSample(sessionID: session, sessionName: "Meeting", speakerIDs: ["system:S1"], speechSeconds: 60,
                             embedding: FloatVector(profileUnit(vector)), condition: .call, weak: false)
        })
    }
    let (m1, m2, m3) = (UUID().uuidString, UUID().uuidString, UUID().uuidString)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [person("JIM", [(m1, profileAxis(0)), (m2, [1, 0.1, 0, 0, 0, 0, 0, 0]),
                                      (m3, [1, 0, 0.1, 0, 0, 0, 0, 0])]),
                       person("MARIA", [(m1, profileAxis(3)), (m3, [0, 0, 0, 1, 0.1, 0, 0, 0])])]
    }
    let calibration = try VoiceProfileService.applyCalibration(store: store)
    let saved = try store.load()
    #expect(saved.calibratedModel == profileModel)
    #expect(saved.calibratedThresholds == calibration.thresholds)
    #expect(saved.calibratedThresholds(for: profileModel) != nil)
    #expect(saved.calibratedThresholds(for: EmbeddingModelID(id: "other", revision: "2")) == nil)

    // A person with samples of another model: refused, and the saved calibration stays as it was.
    try store.update {
        $0.profiles.append(SpeakerProfile(
            id: "SAM", displayName: "Sam", embeddingModel: EmbeddingModelID(id: "other", revision: "2"),
            samples: [VoiceprintSample(sessionID: m2, sessionName: "Meeting", speakerIDs: ["system:S2"],
                                       speechSeconds: 60, embedding: FloatVector(profileAxis(6)), condition: .call,
                                       weak: false)]))
    }
    #expect(throws: HolosError.self) { try VoiceProfileService.applyCalibration(store: store) }
    #expect(try store.load().calibratedThresholds == calibration.thresholds)
}

// MARK: - Export

@Test func peopleExportOmitsEmbeddingsByDefault() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update {
        $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0)), SpeakerProfile(id: "SAM", displayName: "Sam")]
    }
    let plain = String(decoding: try VoiceProfileService.exportPeople(store: store, includeVoiceprints: false),
                       as: UTF8.self)
    #expect(!plain.contains("\"embedding\""), "No embedding key (the model's name is kept as embeddingModel).")
    #expect(plain.contains("\"format\" : \"holos-people\""))
    #expect(plain.contains("Jim") && plain.contains("Sam") && plain.contains("speechSeconds"))
    let full = String(decoding: try VoiceProfileService.exportPeople(store: store, includeVoiceprints: true),
                      as: UTF8.self)
    #expect(full.contains("\"embedding\""))
}

// MARK: - Extractors

/// A 20 s in-person session with mic audio and no speaker labels, for the in-process extractor.
private func profileAudioSession(in temp: TemporaryDirectory) async throws -> URL {
    try await SessionFixtures.makeSession(
        in: temp.url, mode: .inPerson,
        transcript: SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")))
}

private func profileExtractor(_ output: DiarizerOutput, temp: TemporaryDirectory,
                              info: DiarizationEngineInfo = .fake) -> DiarizerVoiceSampleExtractor {
    DiarizerVoiceSampleExtractor(diarizer: FakeDiarizer(outputs: ["mic": output], info: info),
                                 temporaryDirectory: temp.url.appendingPathComponent("tmp", isDirectory: true),
                                 freeSpace: FixedFreeSpace(.max))
}

@Test(.timeLimit(.minutes(1)))
func extractorUsesOverlappingWindowsForShortTurns() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let session = try await profileAudioSession(in: temp)
    let output = DiarizerOutput(
        segments: [RawDiarizationSegment(speaker: "S1", start: 0, end: 10)], centroids: [:],
        windows: [EmbeddingWindow(speaker: "S1", start: 0, end: 10, vector: FloatVector(profileAxis(0)))],
        processingSeconds: 0)
    let extractor = profileExtractor(output, temp: temp)
    let result = try await extractor.turnEmbeddings(session: session, track: "mic",
                                                    turns: [TurnRef(id: "T1", start: 3, end: 6)])
    #expect(result.map(\.turnID) == ["T1"])
    #expect(result.first?.vector.values == profileAxis(0))
    #expect(result.first?.speechSeconds == 3)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: extractor.temporaryDirectory.path)) ?? []
    #expect(leftovers.isEmpty, "The render is deleted.")
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)), "Nothing is written in the session.")
}

@Test(.timeLimit(.minutes(1)))
func extractorIgnoresOtherSpeakerSlotInSharedWindow() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let session = try await profileAudioSession(in: temp)
    let output = DiarizerOutput(
        segments: [RawDiarizationSegment(speaker: "S1", start: 0, end: 6),
                   RawDiarizationSegment(speaker: "S2", start: 6, end: 10)],
        centroids: [:],
        windows: [EmbeddingWindow(speaker: "S1", start: 0, end: 10, vector: FloatVector(profileAxis(0))),
                  EmbeddingWindow(speaker: "S2", start: 0, end: 10, vector: FloatVector(profileAxis(1)))],
        processingSeconds: 0)
    let result = try await profileExtractor(output, temp: temp).turnEmbeddings(
        session: session, track: "mic", turns: [TurnRef(id: "T1", start: 1, end: 5)])
    #expect(result.first?.vector.values == profileAxis(0), "The turn's embedding is its own slot's vector.")
}

@Test(.timeLimit(.minutes(1)))
func extractorSkipsTurnsWithoutADominantSpeaker() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let session = try await profileAudioSession(in: temp)
    let output = DiarizerOutput(
        segments: [RawDiarizationSegment(speaker: "S1", start: 0, end: 5),
                   RawDiarizationSegment(speaker: "S2", start: 5, end: 10)],
        centroids: [:],
        windows: [EmbeddingWindow(speaker: "S1", start: 0, end: 10, vector: FloatVector(profileAxis(0))),
                  EmbeddingWindow(speaker: "S2", start: 0, end: 10, vector: FloatVector(profileAxis(1)))],
        processingSeconds: 0)
    let result = try await profileExtractor(output, temp: temp).turnEmbeddings(
        session: session, track: "mic",
        turns: [TurnRef(id: "T1", start: 3, end: 8), TurnRef(id: "T2", start: 0.5, end: 4.5)])
    #expect(result.map(\.turnID) == ["T2"])
}

@Test(.timeLimit(.minutes(1)))
func extractorRefusesAnotherEmbeddingModel() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let (session, _) = try await profileSession(in: temp)
    var other = DiarizationEngineInfo.fake
    other.embeddingModel = EmbeddingModelID(id: "other", revision: "2")
    let extractor = DiarizerVoiceSampleExtractor(
        diarizer: FakeDiarizer(outputs: [:], info: other),
        temporaryDirectory: temp.url.appendingPathComponent("tmp", isDirectory: true), freeSpace: FixedFreeSpace(.max))
    await #expect(throws: HolosError.self) {
        _ = try await extractor.turnEmbeddings(session: session, track: "system",
                                               turns: [TurnRef(id: "T1", start: 0.5, end: 3.4)])
    }
}

/// An executable shell script in the test's folder.
private func profileScript(_ temp: TemporaryDirectory, _ body: String) throws -> URL {
    let url = temp.url.appendingPathComponent("holos-\(UUID().uuidString).sh")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else { throw HolosError.io("chmod") }
    return url
}

@Test(.timeLimit(.minutes(1)))
func subprocessExtractorReadsEmbeddingsFromAPipe() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let output = TurnEmbeddingsOutput(turnEmbeddings: [
        TurnEmbedding(turnID: "T1", speechSeconds: 3, vector: FloatVector(profileAxis(0))),
        TurnEmbedding(turnID: "T9", speechSeconds: 3, vector: FloatVector(profileAxis(1))),
    ])
    let json = temp.url.appendingPathComponent("out.json")
    try HolosJSON.encoder(pretty: false).encode(output).write(to: json)
    let arguments = temp.url.appendingPathComponent("arguments.txt")
    let script = try profileScript(temp, "printf '%s\\n' \"$@\" > '\(arguments.path)'\ncat '\(json.path)'")
    let extractor = SubprocessVoiceSampleExtractor(executable: script, temporaryDirectory: temp.url)
    let session = temp.url.appendingPathComponent("S.holos")
    let result = try await extractor.turnEmbeddings(session: session, track: "system",
                                                    turns: [TurnRef(id: "T1", start: 0, end: 3),
                                                            TurnRef(id: "T2", start: 5, end: 8)])
    #expect(result == [output.turnEmbeddings[0]], "Only requested turns are kept.")
    let passed = SessionFixtures.text(arguments).split(separator: "\n").map(String.init)
    #expect(passed == SubprocessVoiceSampleExtractor.arguments(session: session, track: "system",
                                                               turnIDs: ["T1", "T2"]))
    #expect(passed == ["speakers", "embed", session.path, "--track", "system", "--turns", "T1,T2", "--json"])

    let failing = SubprocessVoiceSampleExtractor(
        executable: try profileScript(temp, "echo 'Speaker models are not installed.' >&2\nexit 1"),
        temporaryDirectory: temp.url)
    do {
        _ = try await failing.turnEmbeddings(session: session, track: "system",
                                             turns: [TurnRef(id: "T1", start: 0, end: 3)])
        Issue.record("A failing child must throw.")
    } catch let HolosError.unavailable(message) {
        #expect(message == "Speaker models are not installed.")
    }
    let logs = (try FileManager.default.contentsOfDirectory(atPath: temp.url.path)).filter { $0.hasPrefix("holos-embed-") }
    #expect(logs.isEmpty, "The child's error log is deleted.")
}
