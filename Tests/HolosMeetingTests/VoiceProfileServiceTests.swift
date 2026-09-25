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
    let stale = ForgetRecord(kind: .all, sampleIDs: [], turnRememberOff: true)
    try store.appendForgetRecord(stale)
    try VoiceProfileService.perform(stale, store: store, sessionsRoot: temp.url)
    #expect(try !store.load().rememberVoices)
    #expect(try store.load().sampleCount == 0)
    #expect(try store.pendingForgets().isEmpty)

    // A resumed `.all` removes only the samples it lists: the user may have turned remembering back on since.
    try store.update {
        $0.rememberVoices = true
        $0.profiles.append(profilePerson("MARIA", "Maria", vector: profileAxis(2)))
    }
    let resumed = ForgetRecord(kind: .all, sampleIDs: [], turnRememberOff: true)
    try store.appendForgetRecord(resumed)
    // Its store write is done: a crash left only the meetings to clean.
    try store.appendForgetRecord(.stored(resumed.id))
    try VoiceProfileService.perform(resumed, store: store, sessionsRoot: temp.url)
    #expect(try store.load().sampleCount == 1)
    #expect(try store.load().rememberVoices, "A resumed forget never turns remembering off again.")
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
    // The voice data and the recognition results go at once. The exported transcript cannot be rewritten without
    // the manifest, and it may still hold a name recognition gave, so the tombstone waits for a readable one.
    #expect(throws: HolosError.self) {
        try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    }
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(first)))
    #expect(!SessionFixtures.exists(first.appendingPathComponent("speakers/recognition")))
    let waiting = try #require(try store.pendingForgets().first)
    #expect(try store.forgetIsCleaned(waiting.id),
            "Nothing Holos reads names them any more, so voice suggestions carry on meanwhile.")
    #expect(VoiceProfileService.recognitionAllowed(store: store))
    try FileManager.default.removeItem(at: SessionPaths.exports(first))
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    #expect(try store.pendingForgets().isEmpty, "With no exports left to rewrite, it finishes.")

    // A missing manifest, for everything.
    let (second, _, _) = try await profileForgetFixture(temp, store: store)
    try FileManager.default.removeItem(at: SessionPaths.manifest(second))
    try FileManager.default.removeItem(at: SessionPaths.exports(second))
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
    #expect(try VoiceProfileService.perform(stale, store: store, sessionsRoot: temp.url) == 1)
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
    // Its store write is done: a crash left only the meetings to clean.
    try store.appendForgetRecord(.stored(resumed.id))
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
    // Adding Sam's samples reset the calibration; it is restored by hand to check that a refusal keeps it.
    #expect(try store.load().calibratedThresholds == nil)
    try store.update { $0.calibratedThresholds = calibration.thresholds; $0.calibratedModel = profileModel }
    #expect(throws: HolosError.self) { try VoiceProfileService.applyCalibration(store: store) }
    #expect(try store.load().calibratedThresholds == calibration.thresholds)
}

@Test(.timeLimit(.minutes(1)))
func calibrationIsResetWhenTheSamplesItWasMeasuredOnChange() async throws {
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
                       person("MARIA", [(m1, profileAxis(3)), (m3, [0, 0, 0, 1, 0.1, 0, 0, 0])]),
                       person("SAM", [(m2, profileAxis(6))]),
                       SpeakerProfile(id: "ANNA", displayName: "Anna")]
    }
    /// Calibrates, runs `change`, and returns whether the calibration was reset (and the note says so).
    func resets(_ change: () async throws -> Void) async throws -> Bool {
        try VoiceProfileService.applyCalibration(store: store)
        let before = try store.load()
        #expect(before.isCalibrated && before.calibrationResetAt == nil)
        try await change()
        let after = try store.load()
        let note = VoiceProfileService.calibrationResetNote(before: before, after: after)
        #expect((note != nil) == (after.calibratedThresholds == nil))
        return after.calibratedThresholds == nil && after.calibratedModel == nil && after.calibrationResetAt != nil
    }

    // Names, settings, and people without samples leave it.
    #expect(try await !resets { try VoiceProfileService.rename(profileID: "JIM", to: "James", store: store) })
    #expect(try await !resets { try VoiceProfileService.setSuggestions(false, profileID: "JIM", store: store) })
    #expect(try await !resets {
        try VoiceProfileService.setRemember(false, forgetExisting: false, store: store, sessionsRoot: temp.url)
        try VoiceProfileService.setRemember(true, forgetExisting: false, store: store, sessionsRoot: temp.url)
    })
    #expect(try await !resets { try VoiceProfileService.forget(profileID: "ANNA", store: store, sessionsRoot: temp.url) })

    // A merge regroups samples: reset.
    #expect(try await resets { try VoiceProfileService.merge(profileID: "SAM", into: "MARIA", store: store) })

    // A voice learned from a meeting (enrollment): reset.
    let (session, _) = try await profileSession(in: temp)
    #expect(try await resets {
        _ = try await VoiceProfileService.link(
            session: session, speakerID: "system:S1", to: .existing(profileID: "JIM"),
            view: try SessionFixtures.view(session), learnVoice: true, extractor: ProfileFakeExtractor(), store: store)
    })
    // That sample recomputed after an edit (refresh) into another voiceprint: reset.
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: ["T3"])], session: session)
    let refreshed = ProfileFakeExtractor(fallback: profileUnit([0.8, 0.6, 0, 0, 0, 0, 0, 0]))
    #expect(try await resets {
        try await VoiceProfileService.refreshSamples(session: session, extractor: refreshed, store: store)
    })
    #expect(refreshed.requests.count == 1)
    // One sample forgotten: reset.
    let sample = try #require(try store.load().profiles.first { $0.id == "JIM" }?.samples.first)
    #expect(try await resets {
        try VoiceProfileService.forget(sampleID: sample.id, store: store, sessionsRoot: temp.url)
    })
    // The samples of one meeting forgotten (Delete Meeting's "Also forget voice samples"): reset.
    #expect(try await resets {
        let tombstone = ForgetRecord(kind: .session, sampleIDs: [], sessionIDs: [m2])
        try store.appendForgetRecord(tombstone)
        try VoiceProfileService.perform(tombstone, store: store, sessionsRoot: temp.url)
    })
    // Every voice forgotten: reset (a model change is covered by the store's own test).
    #expect(try await resets { try VoiceProfileService.forgetAll(store: store, sessionsRoot: temp.url) })
}

@Test(.timeLimit(.minutes(1)))
func recognitionIsWrittenWhileNoPeopleChangeCanLand() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, record) = try await profileProcessedSession(in: temp, store: nil, forceVoiceData: true)
    let runID = try #require(record.runID)
    let run = try SessionSpeakerStore.readRun(id: runID, session: session)
    let voiceData = try SessionSpeakerStore.readVoiceData(runID: runID, session: session)
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [profilePerson("JIM", "Jim", vector: profileAxis(0))]
    }

    // Jim's suggestions are turned off between the people's last read and the write of the comparison: the change
    // waits for the write (and here gives up after 2 s), so it can never be lost behind a stale comparison.
    let outcome = RecognizeStage.$whileSaving.withValue({
        #expect(throws: HolosError.self) {
            try VoiceProfileService.setSuggestions(false, profileID: "JIM", store: store)
        }
    }) {
        RecognizeStage.run(run, voiceData: voiceData, session: session, store: store)
    }
    guard case .recognized(let result) = outcome else {
        Issue.record("Expected a recognition result, got \(outcome)")
        return
    }
    #expect(result.matches.map(\.profileID) == ["JIM"])
    #expect(try store.load().profiles.first?.recognitionEnabled == true, "The refused change wrote nothing.")
    // Once the comparison is written the change goes through, and the next meeting uses it.
    try VoiceProfileService.setSuggestions(false, profileID: "JIM", store: store)
    guard case .skipped = RecognizeStage.run(run, voiceData: voiceData, session: session, store: store) else {
        Issue.record("Nobody is left to suggest.")
        return
    }
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

// MARK: - Forgetting: the phase a crash left

@Test(.timeLimit(.minutes(1)))
func aForgetThatCrashedBeforeItsStoreWriteStillTurnsRememberingOff() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    _ = try await profileForgetFixture(temp, store: store)
    #expect(try store.load().sampleCount == 1)
    // The tombstone of "Remember voices off, and forget": written, then the process died before the store write.
    // Nothing in the store or the journal said so before; the resume replayed it as a later cleanup retry, which
    // left remembering on and removed only the samples the tombstone listed.
    let tombstone = ForgetRecord(kind: .all, sampleIDs: [], turnRememberOff: true)
    try store.appendForgetRecord(tombstone)
    let leftover = store.directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
    try AtomicFile.write(Data("an older database".utf8), to: leftover)

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try !store.load().rememberVoices, "Turning the setting off is part of the store phase the crash skipped.")
    #expect(try store.load().sampleCount == 0, "So is the sweep of everything the scope covers.")
    #expect(!FileManager.default.fileExists(atPath: leftover.path), "A forget clears atomic-write leftovers.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aResumedForgetLeavesRememberingAndNewerSamplesAlone() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    _ = try await profileForgetFixture(temp, store: store)
    // A tombstone whose store write is done (its `stored` line) and that only failed to clean a meeting: the user
    // has turned remembering back on and a voice was learned since.
    let tombstone = ForgetRecord(kind: .all, sampleIDs: [], turnRememberOff: true)
    try store.appendForgetRecord(tombstone)
    try store.appendForgetRecord(.stored(tombstone.id))

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try store.load().rememberVoices, "A forget that already had its store write never turns it off again.")
    #expect(try store.load().sampleCount == 1, "And removes only the samples it listed.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgettingASampleFollowsItToThePersonItWasMergedInto() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    // A second person in the same meeting, so the meeting holds a speaker linked to each.
    _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S2", to: .new(name: "Maria"),
                                           view: try profileView(session, store: store), learnVoice: true,
                                           extractor: ProfileFakeExtractor(), store: store)
    let maria = try #require(try store.load().profiles.first { $0.displayName == "Maria" }?.id)
    let sample = try #require(try store.load().profiles.first { $0.id == jim }?.samples.first?.id)
    let sessionID = try profileManifestID(session)

    // The tombstone was listed while the sample was Jim's; the merge moved it to Maria before the store write.
    let stale = ForgetRecord(kind: .sample, profileID: jim, sampleIDs: [sample], sessionIDs: [sessionID])
    try store.appendForgetRecord(stale)
    try VoiceProfileService.merge(profileID: jim, into: maria, store: store)
    try VoiceProfileService.perform(stale, store: store, sessionsRoot: temp.url)

    // Cleanup followed the sample to Maria, so her speaker's entries went with the ones of the link that named the
    // person she was merged from. With the tombstone's stale ID, mic:S2's centroid (hers) would have stayed.
    let voice = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(voice.centroids.isEmpty, "Both linked speakers' centroids are gone.")
    #expect(voice.turnEmbeddings.isEmpty)
    #expect(try store.storedForget(stale.id)?.profileID == maria, "The owner is journalled for a later retry.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetDeletesVoiceDataWhoseCentroidStillHoldsAReassignedTurn() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, _) = try await profileForgetFixture(temp, store: store)
    // T2 was the machine's mic:S2; the user moved it to a speaker of their own and linked that speaker to Sam.
    // Sam's speech is therefore inside mic:S2's centroid, which no filter of Sam's clusters can take out.
    _ = try SpeakerEditor.apply([.newSpeaker(speakerID: "user:U1", name: "Sam", turnIDs: ["T2"])],
                                view: try profileView(session, store: store), session: session, source: "cli")
    _ = try await VoiceProfileService.link(session: session, speakerID: "user:U1", to: .new(name: "Sam"),
                                           view: try profileView(session, store: store), learnVoice: false,
                                           extractor: nil, store: store)
    let sam = try #require(try store.load().profiles.first { $0.displayName == "Sam" }?.id)
    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session)?.centroids["mic:S2"] != nil)

    try VoiceProfileService.forget(profileID: sam, store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session) == nil,
            "A centroid that still mixes in the forgotten person's speech is not kept: the voice data goes.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetStaysPendingUntilTheExportsAreRewritten() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, jim) = try await profileForgetFixture(temp, store: store)
    let markdown = SessionPaths.export("md", in: session)
    try FileManager.default.removeItem(at: markdown)
    let exports = SessionPaths.exports(session)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: exports.path)

    #expect(throws: HolosError.self) {
        try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)
    }
    #expect(try store.load().profiles.isEmpty, "The store write happened; only the meeting is unfinished.")
    #expect(try store.pendingForgets().count == 1, "The tombstone stays pending until the exports are written.")
    #expect(!SessionFixtures.exists(markdown))

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exports.path)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(SessionFixtures.exists(markdown),
            "The retry rewrites them, though the recognition file it scrubbed no longer says they are owed.")
    #expect(try store.pendingForgets().isEmpty)
}

// MARK: - Linking: people and labels as they are at the write

@Test(.timeLimit(.minutes(1)))
func anEditIsRefusedWhenThePersonItLinksIsGone() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _) = try await profileProcessedSession(in: temp, store: nil)
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")] }
    let view = try profileView(session, store: store)
    let before = try SessionSpeakerStore.readEdits(session: session).edits.count

    // Another window forgot Jim between this caller reading him and the lines being appended.
    try store.update { $0.profiles.removeAll() }
    #expect(throws: HolosError.self) {
        try SpeakerEditor.apply([.linkProfile(speakerID: "mic:S1", profileID: "JIM"),
                                 .rename(speakerID: "mic:S1", name: "Jim")],
                                view: view, session: session, source: "cli", profiles: store,
                                requirePeople: ["JIM": "Jim"])
    }
    #expect(try SessionSpeakerStore.readEdits(session: session).edits.count == before, "Nothing was appended.")
    #expect(try SessionFixtures.view(session).speakers.first { $0.id == "mic:S1" }?.profileID == nil)

    // A person who is there is marked used in that same locked step, before the lines are appended.
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim", createdAt: Date(),
                                                     lastUsedAt: Date(timeIntervalSince1970: 0))] }
    _ = try SpeakerEditor.apply([.linkProfile(speakerID: "mic:S1", profileID: "JIM"),
                                 .rename(speakerID: "mic:S1", name: "Jim")],
                                view: try profileView(session, store: store), session: session, source: "cli",
                                profiles: store, requirePeople: ["JIM": "Jim"])
    let jim = try #require(try store.load().profiles.first)
    #expect(jim.lastUsedAt > Date(timeIntervalSince1970: 0))
}

@Test(.timeLimit(.minutes(1)))
func aLinkThatChangesNothingIsRefusedWhenAnotherWindowChangedIt() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _) = try await profileProcessedSession(in: temp, store: nil)
    _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S1", to: .new(name: "Jim"),
                                           view: try profileView(session, store: store), learnVoice: false,
                                           extractor: nil, store: store)
    let jim = try #require(try store.load().profiles.first { $0.displayName == "Jim" }?.id)
    // The view this caller holds: mic:S1 is Jim, so linking Jim again changes nothing in it.
    let view = try profileView(session, store: store)
    // Another window links the same speaker to Maria.
    _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S1", to: .new(name: "Maria"),
                                           view: try profileView(session, store: store), learnVoice: false,
                                           extractor: nil, store: store)

    await #expect(throws: HolosError.self) {
        _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S1", to: .existing(profileID: jim),
                                               view: view, learnVoice: false, extractor: nil, store: store)
    }
    let speaker = try #require(try SessionFixtures.view(session).speakers.first { $0.id == "mic:S1" })
    #expect(speaker.name == "Maria", "The other window's link stands; the caller is told to reload.")
}

@Test func aPersonAnotherLinkHasTakenUpIsNotRolledBack() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let made = Date(timeIntervalSince1970: 1_790_000_000)
    var withSample = profilePerson("WITHSAMPLE", "With a sample", vector: profileAxis(0))
    withSample.provisional = true
    try store.update {
        $0.profiles = [
            // Created for the link this call is about to have refused, and never taken up.
            SpeakerProfile(id: "FRESH", displayName: "Fresh", createdAt: made, lastUsedAt: made, provisional: true),
            // Created the same way, but another window linked them in another meeting meanwhile, which clears
            // `provisional` under `profiles.lock` before its lines are appended. Both windows were inside one
            // second, so the two dates are equal and cannot tell this person from the one above: the state is
            // explicit for that reason.
            SpeakerProfile(id: "TAKEN", displayName: "Taken", createdAt: made, lastUsedAt: made),
            // Created, refused, and a voice was learned for them meanwhile.
            withSample,
        ]
    }

    VoiceProfileService.rollBack(["FRESH", "TAKEN", "WITHSAMPLE"], store: store)

    #expect(try store.load().profiles.map(\.id).sorted() == ["TAKEN", "WITHSAMPLE"],
            "Only a person nobody has taken up is removed; the others' meetings would be left pointing at nobody.")
}

@Test(.timeLimit(.minutes(1)))
func aLinkIsRefusedWhenThePersonWasRenamedMeanwhile() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _) = try await profileProcessedSession(in: temp, store: nil)
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")] }
    let view = try profileView(session, store: store)
    let before = try SessionSpeakerStore.readEdits(session: session).edits.count

    // Another window renames Jim between this caller reading him and the lines being appended. The batch's
    // `rename` line still carries "Jim", which is the name the user saw and chose.
    try VoiceProfileService.rename(profileID: "JIM", to: "James", store: store)
    #expect(throws: HolosError.self) {
        try SpeakerEditor.apply([.linkProfile(speakerID: "mic:S1", profileID: "JIM"),
                                 .rename(speakerID: "mic:S1", name: "Jim")],
                                view: view, session: session, source: "cli", profiles: store,
                                requirePeople: ["JIM": "Jim"])
    }
    #expect(try SessionSpeakerStore.readEdits(session: session).edits.count == before, "Nothing was appended.")
    #expect(try store.load().profiles.first?.lastUsedAt == store.load().profiles.first?.createdAt,
            "A refused claim writes nothing at all.")

    // Saving the name the store now has is what goes through.
    _ = try SpeakerEditor.apply([.linkProfile(speakerID: "mic:S1", profileID: "JIM"),
                                 .rename(speakerID: "mic:S1", name: "James")],
                                view: try profileView(session, store: store), session: session, source: "cli",
                                profiles: store, requirePeople: ["JIM": "James"])
    #expect(try SessionFixtures.view(session).speakers.first { $0.id == "mic:S1" }?.name == "James")
}

@Test(.timeLimit(.minutes(1)))
func aRefusedNewPersonIsStillRemoved() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _) = try await profileProcessedSession(in: temp, store: nil)
    let stale = try profileView(session, store: store)
    // Someone renames the speaker, so the view this call holds is stale and its link is refused.
    _ = try SpeakerEditor.apply([.rename(speakerID: "mic:S1", name: "Chair")], view: stale, session: session,
                                source: "cli")

    await #expect(throws: HolosError.self) {
        _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S1", to: .new(name: "Jim"),
                                               view: stale, learnVoice: false, extractor: nil, store: store)
    }
    #expect(try store.load().profiles.isEmpty, "The person created for a refused link is taken back.")
}

// MARK: - Leftover voice renders

@Test func leftoverVoiceRendersAreSweptOnceTheyAreOldEnough() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let renders = temp.url.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
    let left = renders.appendingPathComponent("holos-voice-\(UUID().uuidString)", isDirectory: true)
    let unrelated = renders.appendingPathComponent("holos-voice", isDirectory: true)
    for folder in [left, unrelated] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data("rendered meeting audio".utf8).write(to: left.appendingPathComponent("mic-16k.caf"))

    #expect(DiarizerVoiceSampleExtractor.removeStaleRenders(in: renders) == 0,
            "A render another Holos may be using right now is left alone.")
    #expect(SessionFixtures.exists(left))

    let later = Date().addingTimeInterval(DiarizerVoiceSampleExtractor.staleRenderAge + 60)
    #expect(DiarizerVoiceSampleExtractor.removeStaleRenders(in: renders, now: later) == 1)
    #expect(!SessionFixtures.exists(left), "The rendered copy of the meeting's audio is gone.")
    #expect(SessionFixtures.exists(unrelated), "Only `holos-voice-<token>` folders are swept.")
}

// MARK: - Merging: the meetings follow the person

@Test(.timeLimit(.minutes(1)))
func mergePointsMeetingsAtThePersonTheyWereMergedInto() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    // The meeting's recognition suggests Jim for mic:S2 (the fixture's match).
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }

    try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)

    let recognition = try #require(try SessionSpeakerStore.readRecognition(runID: runID, session: session))
    #expect(recognition.matches.map(\.profileID) == ["MARIA"],
            "The suggestion is the person they were merged into, not a profile ID that is gone.")
    let speaker = try #require(try profileView(session, store: store).speakers.first { $0.id == "mic:S2" })
    #expect(speaker.suggestion?.profileID == "MARIA", "So the meeting still offers a name to confirm.")
    #expect(speaker.suggestion?.profileName == "Maria")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeThatCouldNotReachAMeetingIsFinishedLater() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    let recognition = session.appendingPathComponent("speakers/recognition", isDirectory: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recognition.path)

    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.load().profiles.map(\.id) == ["MARIA"], "The merge itself stands.")
    #expect(try store.pendingForgets().first?.kind == .merge, "The meetings are unfinished business.")
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID == jim)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recognition.path)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "MARIA")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeWhoseStoreWriteNeverHappenedIsDroppedNotReplayed() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    // Maria's sample comes from another speaker model, which is what the merge refuses.
    try store.update {
        $0.profiles.append(SpeakerProfile(
            id: "MARIA", displayName: "Maria", embeddingModel: EmbeddingModelID(id: "other", revision: "1"),
            samples: [VoiceprintSample(sessionID: UUID().uuidString, sessionName: "Earlier meeting",
                                       speakerIDs: ["mic:S1"], speechSeconds: 60,
                                       embedding: FloatVector(profileAxis(3)), condition: .room, weak: false)]))
    }
    // What a refused merge leaves: the record is written before the store update, and that update threw (here,
    // because the two people's samples come from different speaker models).
    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.load().profiles.count == 2, "Both people are still there.")

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID == jim,
            "A merge that never committed must not point any meeting at the other person.")
    #expect(try store.pendingForgets().isEmpty, "And it is dropped, not carried forever.")
    #expect(try store.load().profiles.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func aMergeStaysPendingWhenAMeetingsRecognitionCannotBeRead() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    let file = session.appendingPathComponent("speakers/recognition/\(runID).json")
    let readable = try Data(contentsOf: file)
    try AtomicFile.write(Data("not a recognition result".utf8), to: file)

    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.pendingForgets().first?.kind == .merge,
            "A merge deletes nothing it cannot read; it waits for a Holos that can.")
    #expect(try Data(contentsOf: file) == Data("not a recognition result".utf8), "And leaves the file alone.")

    try AtomicFile.write(readable, to: file)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "MARIA")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeStaysPendingUntilTheExportsAreRewritten() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    let markdown = SessionPaths.export("md", in: session)
    try FileManager.default.removeItem(at: markdown)
    let exports = SessionPaths.exports(session)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: exports.path)

    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.pendingForgets().first?.kind == .merge)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exports.path)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(SessionFixtures.exists(markdown),
            "The retry rewrites them, though the recognition it retargeted no longer says they are owed.")
    #expect(try store.pendingForgets().isEmpty)
}

// MARK: - Remember voices governs recognition, not only new voice data

@Test(.timeLimit(.minutes(1)))
func keptSamplesAreNotUsedWhileRememberVoicesIsOff() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, _) = try await profileForgetFixture(temp, store: store)
    let suggestion = { try profileView(session, store: store).speakers.first { $0.id == "mic:S2" }?.suggestion }
    #expect(try suggestion()?.profileName == "Jim", "With the setting on, the stored result suggests a name.")

    // Turned off, keeping the samples: "Kept samples are not used while Remember voices is off" (People window).
    #expect(try VoiceProfileService.setRemember(false, forgetExisting: false, store: store,
                                                sessionsRoot: temp.url) == 0)

    let snapshot = try SpeakerSessionSnapshot.load(
        session: session, profileNames: VoiceProfileService.profileNames(store: store),
        applyRecognition: VoiceProfileService.recognitionAllowed(store: store))
    #expect(snapshot.recognition == nil, "The stored result is not even read.")
    #expect(snapshot.projection?.speakers.first { $0.id == "mic:S2" }?.suggestion == nil)
    #expect(try store.load().sampleCount == 1, "The samples are kept, as the user chose.")
    #expect(SessionFixtures.exists(session.appendingPathComponent("speakers/recognition")),
            "And nothing is deleted, so turning it back on brings the suggestions back.")

    try VoiceProfileService.setRemember(true, forgetExisting: false, store: store, sessionsRoot: temp.url)
    #expect(try suggestion()?.profileName == "Jim")
}

@Test(.timeLimit(.minutes(1)))
func aMergeThatCommittedBeforeItsMarkerIsStillFinished() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    // The crash window on the other side of the store write: the merge committed, the process went before its
    // `stored` line. The journal alone cannot tell this from a merge that was refused; the store can.
    let record = ForgetRecord(kind: .merge, profileID: jim, targetProfileID: "MARIA")
    try store.appendForgetRecord(record)
    try store.update { database in
        let samples = database.profiles.first { $0.id == jim }?.samples ?? []
        database.profiles.removeAll { $0.id == jim }
        guard let target = database.profiles.firstIndex(where: { $0.id == "MARIA" }) else { return }
        database.profiles[target].samples = samples
        database.profiles[target].embeddingModel = profileModel
        // What the merge's own write records: this merge is what removed Jim.
        database.mergedInto = [jim: "MARIA"]
    }

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "MARIA", "The meetings are finished, not dropped: the merge did happen.")
    #expect(try store.pendingForgets().isEmpty, "And it is finished, not left behind.")
}

@Test func aPersonAMergeAdoptedIsNotRolledBack() throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    // Created for a link that has not been saved, as `link(to: .new)` creates one.
    try store.update {
        $0.profiles = [SpeakerProfile(id: "FRESH", displayName: "Fresh", provisional: true),
                       SpeakerProfile(id: "OLD", displayName: "Old")]
    }
    // Another window merges an existing person into them: adoption without any link.
    try VoiceProfileService.merge(profileID: "OLD", into: "FRESH", store: store, sessionsRoot: temp.url)
    #expect(try store.load().profiles.first?.provisional == nil,
            "Any write that changes the person ends the provisional state, not only a link's claim.")

    VoiceProfileService.rollBack(["FRESH"], store: store)

    #expect(try store.load().profiles.map(\.id) == ["FRESH"],
            "Removing them would have lost both people: the merge already took the other one away.")
}

@Test(.timeLimit(.minutes(1)))
func forgettingAPersonFollowsTheirSamplesThroughAMerge() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S2", to: .new(name: "Maria"),
                                           view: try profileView(session, store: store), learnVoice: true,
                                           extractor: ProfileFakeExtractor(), store: store)
    let maria = try #require(try store.load().profiles.first { $0.displayName == "Maria" }?.id)
    let samples = try #require(try store.load().profiles.first { $0.id == jim }?.samples.map(\.id))

    // The tombstone was listed while the samples were Jim's; the merge moved them to Maria before the store write.
    let stale = ForgetRecord(kind: .profile, profileID: jim, sampleIDs: samples,
                             sessionIDs: [try profileManifestID(session)])
    try store.appendForgetRecord(stale)
    try VoiceProfileService.merge(profileID: jim, into: maria, store: store, sessionsRoot: temp.url)
    try VoiceProfileService.perform(stale, store: store, sessionsRoot: temp.url)

    // Cleanup followed the samples to Maria, so her entries went too. With the tombstone's stale ID, the match the
    // merge had already pointed at her would have survived its only supporting sample being forgotten.
    let voice = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(voice.centroids.isEmpty)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.isEmpty == true)
    #expect(try store.storedForget(stale.id)?.profileID == maria)
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aRejectionThatChangesNothingIsDecidedOnTheCurrentLabels() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, jim) = try await profileForgetFixture(temp, store: store)

    let first = try VoiceProfileService.reject(session: session, speakerID: "mic:S2", profileID: jim,
                                               view: try profileView(session, store: store), store: store)
    #expect(first != nil, "The first rejection is saved.")
    let again = try VoiceProfileService.reject(session: session, speakerID: "mic:S2", profileID: jim,
                                               view: try profileView(session, store: store), store: store)
    #expect(again == nil, "Repeating it changes nothing, and the editor says so from the current labels.")

    // With Remember voices off, the labels this returns carry no automatic name either: it passes the store.
    try VoiceProfileService.setRemember(false, forgetExisting: false, store: store, sessionsRoot: temp.url)
    let saved = try VoiceProfileService.reject(session: session, speakerID: "mic:S1", profileID: jim,
                                               view: try profileView(session, store: store), store: store)
    #expect(saved?.recognition == nil, "Kept samples are not used while Remember voices is off.")
}

@Test(.timeLimit(.minutes(1)))
func aVoiceForgottenWhileItWasLearnedIsNotPutBack() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    try store.update { $0.rememberVoices = true }
    let (session, _) = try await profileProcessedSession(in: temp, store: nil, forceVoiceData: true)
    let sessionID = try profileManifestID(session)
    // Another window forgets this meeting's voices while the extractor is still working.
    let extractor = ProfileFakeExtractor(hook: { _ in
        try VoiceProfileService.forget(sessionID: sessionID, store: store)
    })

    await #expect(throws: HolosError.self) {
        _ = try await VoiceProfileService.link(session: session, speakerID: "mic:S1", to: .new(name: "Jim"),
                                               view: try SessionFixtures.view(session), learnVoice: true,
                                               extractor: extractor, store: store)
    }

    #expect(try store.load().sampleCount == 0,
            "The forget was the later request, so the voice computed before it is not saved after it.")
    #expect(try store.load().profiles.map(\.displayName) == ["Jim"], "The name is saved; only the voice is not.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeFollowsItsTargetOnwards() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update {
        $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria"))
        $0.profiles.append(SpeakerProfile(id: "CARLOS", displayName: "Carlos"))
    }
    // Jim was merged into Maria and the store write committed, but the meetings were not reached yet.
    let pending = ForgetRecord(kind: .merge, profileID: jim, targetProfileID: "MARIA")
    try store.appendForgetRecord(pending)
    try store.appendForgetRecord(.stored(pending.id))
    try store.update { database in
        let samples = database.profiles.first { $0.id == jim }?.samples ?? []
        database.profiles.removeAll { $0.id == jim }
        guard let target = database.profiles.firstIndex(where: { $0.id == "MARIA" }) else { return }
        database.profiles[target].samples = samples
        database.profiles[target].embeddingModel = profileModel
        database.mergedInto = [jim: "MARIA"]
    }
    // Meanwhile another window merges Maria onwards into Carlos.
    try VoiceProfileService.merge(profileID: "MARIA", into: "CARLOS", store: store, sessionsRoot: temp.url)

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "CARLOS", "Writing the person Maria became, not the ID she had when the merge was recorded.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeStaysPendingWhenAMeetingsManifestCannotBeRead() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    let manifest = SessionPaths.manifest(session)
    let readable = try Data(contentsOf: manifest)
    try AtomicFile.write(Data("{\"schemaVersion\":1,".utf8), to: manifest)

    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.pendingForgets().first?.kind == .merge,
            "A manifest that cannot be read now is not an absent one; the meeting is tried again.")

    try AtomicFile.write(readable, to: manifest)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "MARIA")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func recognitionIsNotUsedWhileAForgetIsUnfinished() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    _ = try await profileForgetFixture(temp, store: store)
    #expect(VoiceProfileService.recognitionAllowed(store: store))

    // What a crash between a forget's store write and its meetings leaves: the results still name the person.
    let stranded = ForgetRecord(kind: .profile, profileID: "SOMEONE", sampleIDs: [])
    try store.appendForgetRecord(stranded)
    try store.appendForgetRecord(.stored(stranded.id))
    #expect(!VoiceProfileService.recognitionAllowed(store: store),
            "Until the meetings are cleaned, a name the user asked to forget is not shown or exported.")

    try store.appendForgetRecord(.done(stranded.id))
    #expect(VoiceProfileService.recognitionAllowed(store: store))

    // A merge is not a forget: it renames, it removes nothing, so it does not hold recognition back.
    let merge = ForgetRecord(kind: .merge, profileID: "A", targetProfileID: "B")
    try store.appendForgetRecord(merge)
    #expect(VoiceProfileService.recognitionAllowed(store: store))
}

@Test(.timeLimit(.minutes(1)))
func aMergeIsNotRecoveredWhenSomethingElseRemovedItsSource() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    // A merge whose store write never happened, and a forget that removed the same person afterwards. The person
    // is gone and the target is there, which is what a committed merge looks like from outside.
    let record = ForgetRecord(kind: .merge, profileID: jim, targetProfileID: "MARIA")
    try store.appendForgetRecord(record)
    try VoiceProfileService.forget(profileID: jim, store: store, sessionsRoot: temp.url)

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    let recognition = try SessionSpeakerStore.readRecognition(runID: runID, session: session)
    #expect(recognition?.matches.isEmpty == true,
            "The forget took the name out; a merge that never happened must not put Maria's in.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeChainFollowsOnlyCommittedMerges() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update {
        $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria"))
        $0.profiles.append(profilePerson("CARLOS", "Carlos", vector: profileAxis(3)))
    }
    // Jim into Maria: committed, meetings not reached.
    let pending = ForgetRecord(kind: .merge, profileID: jim, targetProfileID: "MARIA")
    try store.appendForgetRecord(pending)
    try store.appendForgetRecord(.stored(pending.id))
    try store.update { database in
        database.profiles.removeAll { $0.id == jim }
        database.mergedInto = [jim: "MARIA"]
    }
    // Maria into Carlos: refused, because their samples come from different speaker models. Its record is written
    // before the store update that throws, so the journal holds a merge that never happened.
    try store.update { database in
        guard let maria = database.profiles.firstIndex(where: { $0.id == "MARIA" }) else { return }
        database.profiles[maria].embeddingModel = EmbeddingModelID(id: "other", revision: "1")
        database.profiles[maria].samples = [VoiceprintSample(
            sessionID: UUID().uuidString, sessionName: "Earlier", speakerIDs: ["mic:S1"], speechSeconds: 60,
            embedding: FloatVector(profileAxis(4)), condition: .room, weak: false)]
    }
    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: "MARIA", into: "CARLOS", store: store, sessionsRoot: temp.url)
    }

    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)

    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "MARIA", "Maria is still there, so the chain stops at her; a refused merge leads nowhere.")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func recognitionIsNotUsedWhileAForgetLineCannotBeRead() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    _ = try await profileForgetFixture(temp, store: store)
    #expect(VoiceProfileService.recognitionAllowed(store: store))

    // A forget of a newer Holos: this build cannot decode its kind, so it cannot resume it either, and its
    // meetings may still name whoever it removed.
    let line = Data("{\"schemaVersion\":1,\"id\":\"\(UUID().uuidString)\",\"kind\":\"quarantine\",\"state\":\"pending\"}\n".utf8)
    try AtomicFile.append(line, to: store.forgetJournalURL)

    #expect(!VoiceProfileService.recognitionAllowed(store: store))
    #expect(try store.pendingForgets().isEmpty, "This build cannot see it as pending; the gate still holds.")
}

@Test(.timeLimit(.minutes(1)))
func aMergeStaysPendingWhenAMeetingHoldsUnknownRecognitionFiles() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, runID, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    let unknown = session.appendingPathComponent("speakers/recognition/from-a-newer-holos.txt")
    try AtomicFile.write(Data("{}".utf8), to: unknown)

    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.pendingForgets().first?.kind == .merge,
            "An entry this build does not know may name the person too; a merge deletes nothing, so it waits.")
    #expect(SessionFixtures.exists(unknown), "And leaves it alone.")

    try FileManager.default.removeItem(at: unknown)
    try VoiceProfileService.resumePendingForgets(store: store, sessionsRoot: temp.url)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session)?.matches.first?.profileID
            == "MARIA")
    #expect(try store.pendingForgets().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aMergeStaysPendingWhenAMeetingFolderCannotBeInspected() async throws {
    let temp = try TemporaryDirectory("profiles")
    defer { temp.remove() }
    let store = profileStore(temp)
    let (session, _, jim) = try await profileForgetFixture(temp, store: store)
    try store.update { $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria")) }
    #expect(chmod(session.path, 0) == 0)
    defer { chmod(session.path, 0o700) }

    #expect(throws: HolosError.self) {
        try VoiceProfileService.merge(profileID: jim, into: "MARIA", store: store, sessionsRoot: temp.url)
    }
    #expect(try store.pendingForgets().first?.kind == .merge,
            "A folder that cannot be inspected has not been visited; only a missing manifest means not a meeting.")
}
