import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// MeetingPostProcessor stages (docs/meeting-design.md §4.7) and `holos session diarize` (§5.5 PR7b), all with
// FakeDiarizer on generated audio.

// MARK: - Helpers

/// An in-person session: 20 s of mic audio and two speakers' words alternating every 5 s.
private func postProcessorSession(in root: URL, mode: MeetingMode? = .inPerson,
                                  legacyExports: Bool = false) async throws -> (session: URL, transcript: Transcript) {
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: root, mode: mode, transcript: transcript,
                                                        legacyExports: legacyExports)
    return (session, transcript)
}

/// A call: 20 s on each track, two speakers alternating on each.
private func postProcessorCall(in root: URL, othersInRoom: Bool) async throws -> (session: URL, transcript: Transcript) {
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")
                                                + SessionFixtures.alternatingSegments(track: "system"))
    let session = try await SessionFixtures.makeSession(
        in: root, source: .microphoneAndSystem, audioSeconds: ["mic": 20, "system": 20], mode: .call,
        othersInRoom: othersInRoom, transcript: transcript)
    return (session, transcript)
}

private func postProcessorFake(_ tracks: [String] = ["mic"], error: HolosError? = nil) -> FakeDiarizer {
    var outputs: [String: DiarizerOutput] = [:]
    for track in tracks { outputs[track] = SessionFixtures.alternatingOutput() }
    return FakeDiarizer(outputs: outputs, error: error)
}

private func postProcessor(_ diarizer: (any SpeakerDiarizer)? = postProcessorFake(),
                           options: PostProcessingOptions = .init(),
                           freeSpace: any FreeSpaceProvider = FixedFreeSpace(.max)) -> MeetingPostProcessor {
    MeetingPostProcessor(diarizer: diarizer, options: options, freeSpace: freeSpace)
}

private func postProcessorStage(_ record: PostProcessingRecord, _ stage: PostProcessingStage) -> StageOutcome? {
    record.stages.last { $0.stage == stage }
}

private func postProcessorRecordOnDisk(_ session: URL) throws -> PostProcessingRecord {
    try AtomicFile.readJSON(PostProcessingRecord.self, from: SessionPaths.postprocess(session))
}

/// Exports that exist, by extension.
private func postProcessorExports(_ session: URL) -> [String] {
    ["md", "json", "txt"].filter { SessionFixtures.exists(SessionPaths.export($0, in: session)) }
}

/// Polls `condition` every 5 ms for up to 10 s.
private func postProcessorEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A diarizer that waits until `open()` before answering, so a test can look at the session mid-run.
private final class GatedDiarizer: SpeakerDiarizer {
    private let fake: FakeDiarizer
    private let gate = SharedValue(false)
    private let entered = SharedValue(false)

    init(_ fake: FakeDiarizer) { self.fake = fake }

    var isWaiting: Bool { entered.value }
    func open() { gate.set(true) }

    func engineInfo() async throws -> DiarizationEngineInfo { try await fake.engineInfo() }

    func diarize(_ request: DiarizationRequest,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput {
        entered.set(true)
        while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
        return try await fake.diarize(request, progress: progress)
    }
}

// MARK: - Stages

@Test(.timeLimit(.minutes(1)))
func postProcessorWritesRunHeadAndExports() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, transcript) = try await postProcessorSession(in: temp.url)
    let reports = SharedValue<[PostProcessingProgress]>([])
    let record = try await postProcessor().run(session: session, lease: nil) { progress in
        reports.update { $0.append(progress) }
    }

    #expect(record.state == .succeeded)
    #expect(record.transcriptID == transcript.id)
    #expect(record.othersInRoom == false)
    #expect(record.pid == getpid())
    #expect(record.progress == nil)
    #expect(record.stages.map(\.stage) == [.transcript, .render, .diarize, .align, .export])
    #expect(record.stages.allSatisfy { $0.result == .succeeded })
    #expect(record.message == "Labelled 2 speakers in 4 turns.")
    let runID = try #require(record.runID)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == runID)
    let run = try SessionSpeakerStore.readRun(id: runID, session: session)
    #expect(run.transcriptID == transcript.id)
    #expect(run.speakers.map(\.id) == ["mic:S1", "mic:S2"])
    #expect(run.turns.count == 4)
    #expect(run.engine == .fake)
    // Dates keep whole seconds on disk (HolosJSON), so compare with the record after the same round trip.
    let roundTripped = try HolosJSON.decoder().decode(PostProcessingRecord.self,
                                                      from: HolosJSON.encoder().encode(record))
    #expect(try postProcessorRecordOnDisk(session) == roundTripped)

    for ext in ["md", "json", "txt"] {
        let url = SessionPaths.export(ext, in: session)
        #expect(SessionFixtures.mode(url) == 0o400, "transcript.\(ext) is a read-only generated file.")
    }
    let generated = try AtomicFile.readJSON(SessionExports.GeneratedRecord.self,
                                            from: SessionPaths.generatedExports(session))
    #expect(generated.pending == nil)
    for ext in ["md", "json", "txt"] {
        let data = try Data(contentsOf: SessionPaths.export(ext, in: session))
        #expect(generated.files["transcript.\(ext)"] == SessionExports.sha256(data))
    }
    let text = SessionFixtures.text(SessionPaths.export("txt", in: session))
    #expect(text.hasPrefix("Speaker 1  00:00\nmict1w1 mict1w2"))
    #expect(text.contains("Speaker 2  00:05\nmict2w1"))

    #expect(!SessionFixtures.exists(SessionPaths.derived(session)), "Renders are deleted.")
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)), "Normal meetings store no voice data.")
    #expect(try !SessionArchive.isProcessing(at: session), "The lease the run took is released.")
    let stages = reports.value.map(\.stage)
    #expect(stages.first == .transcript && stages.last == .export)
    #expect([PostProcessingStage.render, .diarize, .align].allSatisfy(stages.contains))
}

@Test(.timeLimit(.minutes(1)))
func voiceDataOnlyWhenForced() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let record = try await postProcessor(options: PostProcessingOptions(forceVoiceData: true))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    let runID = try #require(record.runID)
    let url = SessionPaths.voiceData(runID, in: session)
    #expect(SessionFixtures.mode(url) == 0o600)
    let voice = try #require(try SessionSpeakerStore.readVoiceData(runID: runID, session: session))
    #expect(Set(voice.centroids.keys) == ["mic:S1", "mic:S2"])
    #expect(!voice.turnEmbeddings.isEmpty)
    let values = try SessionPaths.voiceDirectory(session).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
}

@Test(.timeLimit(.minutes(1)))
func rememberOnStoresNoVoiceData() async throws {
    // PR10 adds the profile store ("Remember voices"); until then no setting exists, and post-processing must
    // persist no embedding anywhere: no speakers/voice/, and no vector in any file it writes.
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let record = try await postProcessor().run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(!SessionFixtures.exists(SessionPaths.voiceDirectory(session)))
    // Every FakeDiarizer centroid and window vector is a unit vector along one axis of 8.
    let vectors = (0..<8).map { axis -> String in
        var values = [Float](repeating: 0, count: 8)
        values[axis] = 1
        let encoded = (try? HolosJSON.encoder(pretty: false).encode(FloatVector(values))) ?? Data()
        return String(decoding: encoded, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    for (path, data) in SessionFixtures.files(in: session) {
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("centroids") && !text.contains("turnEmbeddings"), "\(path) holds no voice data.")
        #expect(!vectors.contains { text.contains($0) }, "\(path) holds no vector.")
    }
}

@Test(.timeLimit(.minutes(1)))
func missingDiarizerSkipsSpeakersButExports() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let record = try await postProcessor(nil).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.runID == nil)
    let diarize = try #require(postProcessorStage(record, .diarize))
    #expect(diarize.result == .skipped)
    #expect(diarize.message == SpeakerAnalysis.modelsMissing)
    #expect(record.message == "No speaker labels: speaker models are not installed. Install them from Setup, or run holos setup --speakers.")
    #expect(postProcessorStage(record, .export)?.result == .succeeded)
    #expect(try SessionSpeakerStore.readHead(session: session) == nil)
    #expect(try SessionSpeakerStore.runIDs(session: session).isEmpty)
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)), "Nothing is rendered without a diarizer.")
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).hasPrefix("Microphone  00:00\n"))
}

@Test(.timeLimit(.minutes(1)))
func diarizerFailureIsRecorded() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let record = try await postProcessor(postProcessorFake(error: .unavailable("The engine broke.")))
        .run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(postProcessorStage(record, .render)?.result == .succeeded)
    #expect(postProcessorStage(record, .diarize)?.result == .failed)
    #expect(postProcessorStage(record, .diarize)?.message == "The engine broke.")
    #expect(postProcessorStage(record, .align)?.result == .skipped)
    #expect(postProcessorStage(record, .export)?.result == .succeeded)
    #expect(record.message == "Speaker labelling failed: The engine broke.")
    #expect(record.runID == nil)
    #expect(postProcessorExports(session) == ["md", "json", "txt"])
    #expect(try postProcessorRecordOnDisk(session).state == .partial)
}

@Test(.timeLimit(.minutes(1)))
func diskLowStopSkipsRender() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let record = try await postProcessor(options: PostProcessingOptions(stopReason: .diskLow))
        .run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(postProcessorStage(record, .render)?.result == .skipped)
    #expect(postProcessorStage(record, .render)?.message == SpeakerAnalysis.noDiskSpace)
    #expect(record.message == SpeakerAnalysis.noDiskSpace)
    #expect(postProcessorExports(session) == ["md", "json", "txt"])
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))
}

@Test(.timeLimit(.minutes(1)))
func lowFreeSpaceSkipsRender() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let record = try await postProcessor(freeSpace: FixedFreeSpace(500_000_000)).run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(postProcessorStage(record, .render)?.result == .skipped)
    #expect(postProcessorStage(record, .render)?.message == SpeakerAnalysis.noDiskSpace)
    #expect(postProcessorExports(session) == ["md", "json", "txt"])
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))
    // 20 s of render needs 640 kB on top of the 1 GB headroom.
    #expect(SpeakerAnalysis.renderAllowed(freeBytes: 1_000_640_000, renderSeconds: 20))
    #expect(!SpeakerAnalysis.renderAllowed(freeBytes: 1_000_639_999, renderSeconds: 20))
}

@Test(.timeLimit(.minutes(1)))
func callWithoutOthersInRoomMakesMicMe() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorCall(in: temp.url, othersInRoom: false)
    let record = try await postProcessor(postProcessorFake(["system"])).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.othersInRoom == false)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.tracks.first { $0.track == "mic" }?.policy == .channel(speakerID: "mic:me", displayName: "Me"))
    #expect(run.tracks.first { $0.track == "system" }?.policy == .diarized)
    #expect(run.speakers.contains { $0.id == "mic:me" && $0.displayName == "Me" })
    #expect(run.speakers.contains { $0.id == "system:S1" })
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).contains("Me  00:00\n"))
}

@Test(.timeLimit(.minutes(1)))
func othersInRoomOverride() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorCall(in: temp.url, othersInRoom: false)
    let record = try await postProcessor(postProcessorFake(["mic", "system"]),
                                         options: PostProcessingOptions(othersInRoom: true))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.othersInRoom == true)
    #expect(try postProcessorRecordOnDisk(session).othersInRoom == true)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.tracks.first { $0.track == "mic" }?.policy == .diarized)
    #expect(run.speakers.contains { $0.id == "mic:S1" })
    #expect(!run.speakers.contains { $0.id == "mic:me" })
}

@Test(.timeLimit(.minutes(1)))
func editedHeadNeedsForce() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let first = try await postProcessor().run(session: session, lease: nil)
    let firstRun = try #require(first.runID)
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Jim")], session: session)

    let refused = try await postProcessor().run(session: session, lease: nil)
    #expect(refused.state == .partial)
    #expect(refused.message == SpeakerAnalysis.editedHead)
    for stage in [PostProcessingStage.render, .diarize, .align] {
        #expect(postProcessorStage(refused, stage)?.result == .skipped)
        #expect(postProcessorStage(refused, stage)?.message == SpeakerAnalysis.editedHead)
    }
    #expect(refused.runID == firstRun, "The edited head stays, and the exports still use it.")
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == firstRun)
    #expect(try SessionSpeakerStore.runIDs(session: session) == [firstRun])
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).hasPrefix("Jim  00:00\n"))

    let forced = try await postProcessor(options: PostProcessingOptions(force: true)).run(session: session, lease: nil)
    #expect(forced.state == .succeeded)
    let newRun = try #require(forced.runID)
    #expect(newRun != firstRun)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == newRun)
    #expect(postProcessorStage(forced, .align)?.message == "Kept 1 name.")
    #expect(forced.message == "Labelled 2 speakers in 4 turns. Kept 1 name.")
    let carried = try SessionSpeakerStore.readEdits(session: session).edits.filter { $0.baseRunID == newRun }
    #expect(carried.count == 1)
    #expect(carried.first?.source == "carry")
    #expect(carried.first?.action == .rename(speakerID: "mic:S1", name: "Jim"))
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let projection = try #require(snapshot.projection)
    #expect(projection.speakers.first { $0.id == "mic:S1" }?.name == "Jim")
    #expect(projection.otherRunEditCount == 1, "The old rename stays in the journal under the old run.")
    #expect(projection.staleEdits.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func damagedHeadIsReplaced() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let first = try await postProcessor().run(session: session, lease: nil)
    let firstRun = try #require(first.runID)
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Jim")], session: session)
    try AtomicFile.write(Data("not json".utf8), to: SessionPaths.head(session))
    // The snapshot tells the user to relabel (SpeakerSnapshotDiagnostics.notes); relabelling must then work.
    #expect(try SpeakerSessionSnapshot.load(session: session).diagnostics.notes.first?
        .contains("holos session diarize --force") == true)

    let relabelled = try await postProcessor(options: PostProcessingOptions(force: true))
        .run(session: session, lease: nil)
    #expect(relabelled.state == .succeeded)
    let newRun = try #require(relabelled.runID)
    #expect(newRun != firstRun)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == newRun)
    #expect(relabelled.message?.contains(SpeakerAnalysis.previousUnreadable) == true)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.runProblem == nil && snapshot.run?.id == newRun)
    #expect(snapshot.diagnostics.notes == [])
}

@Test(.timeLimit(.minutes(1)))
func changedTranscriptRelabels() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let first = try await postProcessor().run(session: session, lease: nil)
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S2", name: "Maria")], session: session)
    let revised = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    try await SessionFixtures.saveTranscript(revised, in: session)

    // No --force: the head was built from another transcript, so it is replaced and the name carried.
    let record = try await postProcessor().run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.transcriptID == revised.id)
    let runID = try #require(record.runID)
    #expect(runID != first.runID)
    let run = try SessionSpeakerStore.readRun(id: runID, session: session)
    #expect(run.transcriptID == revised.id)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.transcript.id == revised.id)
    #expect(!snapshot.transcriptChanged)
    #expect(snapshot.projection?.speakers.first { $0.id == "mic:S2" }?.name == "Maria")
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).contains("Maria  00:05\n"))
}

@Test(.timeLimit(.minutes(1)))
func changedTranscriptWithoutNewLabelsExportsTheCurrentTranscript() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, first) = try await postProcessorSession(in: temp.url)
    let labelled = try await postProcessor().run(session: session, lease: nil)
    let headRun = try #require(labelled.runID)
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Jim")], session: session)
    let revised = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")
                                             + [SessionFixtures.segment(["addedword"], track: "mic", start: 19)])
    try await SessionFixtures.saveTranscript(revised, in: session)
    let txt = SessionPaths.export("txt", in: session)
    let json = SessionPaths.export("json", in: session)

    // No speaker models: the exports show the revised transcript without speakers, never the earlier one.
    let missing = try await postProcessor(nil).run(session: session, lease: nil)
    #expect(missing.state == .succeeded)
    #expect(missing.transcriptID == revised.id)
    #expect(missing.runID == nil)
    #expect(missing.message == SpeakerAnalysis.modelsMissingRecord)
    #expect(SessionFixtures.text(txt).hasPrefix("Microphone  00:00\n"))
    #expect(SessionFixtures.text(txt).contains("addedword"))
    #expect(!SessionFixtures.text(txt).contains("Jim"))
    #expect(SessionFixtures.text(json).contains(revised.id))
    #expect(!SessionFixtures.text(json).contains(first.id))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == headRun,
            "The earlier labels stay for the review window, which reports the change.")
    #expect(try SpeakerSessionSnapshot.load(session: session).transcriptChanged)

    // The diarizer fails: the same exports, and the state is partial.
    let failed = try await postProcessor(postProcessorFake(error: .unavailable("The engine broke.")))
        .run(session: session, lease: nil)
    #expect(failed.state == .partial)
    #expect(failed.runID == nil)
    #expect(SessionFixtures.text(txt).contains("addedword"))
    #expect(!SessionFixtures.text(txt).contains("Jim"))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == headRun)
}

@Test(.timeLimit(.minutes(1)))
func damagedMeetingInfoStillExports() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url, legacyExports: true)
    try AtomicFile.write(Data("{not json".utf8), to: SessionPaths.meetingInfo(session))
    let record = try await postProcessor().run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(record.message == "Cannot read meeting.json: meeting.json is damaged or was not written by Holos.")
    #expect(postProcessorStage(record, .align)?.result == .skipped)
    #expect(postProcessorStage(record, .export)?.result == .succeeded)
    #expect(postProcessorExports(session) == ["md", "json", "txt"])
    #expect(SessionFixtures.exists(SessionPaths.generatedExports(session)))
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.meeting == MeetingInfo.inferred(sessionID: snapshot.manifest.id, source: snapshot.manifest.source,
                                                     createdAt: snapshot.manifest.createdAt),
            "A damaged meeting.json reads as the inferred meeting.")
}

@Test(.timeLimit(.minutes(1)))
func twoDiarizedTracksGetMaximumOnlyHints() {
    let meeting = MeetingInfo(sessionID: "S", mode: .call, othersInRoom: true, expectedSpeakers: 4,
                              createdAt: SessionFixtures.date)
    func hint(_ speakers: SpeakerCountHint?, tracks: Int) -> SpeakerCountHint? {
        SpeakerAnalysis.speakerHint(options: PostProcessingOptions(speakers: speakers), meeting: meeting,
                                    diarizedTracks: tracks)
    }
    #expect(hint(SpeakerCountHint(exactly: 5), tracks: 1) == SpeakerCountHint(exactly: 5))
    #expect(hint(SpeakerCountHint(exactly: 5), tracks: 2) == SpeakerCountHint(maximum: 5))
    #expect(hint(SpeakerCountHint(minimum: 2, maximum: 6), tracks: 2) == SpeakerCountHint(maximum: 6))
    #expect(hint(SpeakerCountHint(minimum: 3), tracks: 2) == nil)
    #expect(hint(nil, tracks: 1) == SpeakerCountHint(minimum: 3, maximum: 5))
    #expect(hint(nil, tracks: 2) == SpeakerCountHint(maximum: 5))
}

@Test(.timeLimit(.minutes(1)))
func derivedClearedAtStartAndEnd() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let derived = SessionPaths.derived(session)
    try AtomicFile.ensurePrivateDirectory(derived)
    try AtomicFile.write(Data("left over".utf8), to: derived.appendingPathComponent("x.caf"))
    // Keeping renders shows the leftover was removed at the start: only this run's render remains.
    let kept = try await postProcessor(postProcessorFake(error: .unavailable("fails")),
                                       options: PostProcessingOptions(keepDerived: true))
        .run(session: session, lease: nil)
    #expect(kept.state == .partial)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: derived.path)) ?? []) == ["mic-16k.caf"])

    try AtomicFile.write(Data("left over".utf8), to: derived.appendingPathComponent("x.caf"))
    let record = try await postProcessor(postProcessorFake(error: .unavailable("fails")))
        .run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(!SessionFixtures.exists(derived), "derived/ is deleted whatever happened.")
}

@Test(.timeLimit(.minutes(1)))
func noSpeechFoundLabelsNoSpeakers() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    // The engine found no speech: every word is an unknown speaker's.
    let record = try await postProcessor(FakeDiarizer(outputs: [:])).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.message == "No speakers were found in the audio.")
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.speakers.isEmpty)
    #expect(run.turns.allSatisfy { $0.speakerID == nil })
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).hasPrefix("Unknown speaker  00:00\n"))
    let summary = SessionDiarizeCommand.summary(record, session: session)
    #expect(summary.hasPrefix("No speakers were found in the audio (run \(try #require(record.runID).prefix(8))…)."))
}

@Test(.timeLimit(.minutes(1)))
func noTranscriptSkipsEverything() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: nil)
    let record = try await postProcessor().run(session: session, lease: nil)
    #expect(record.state == .skipped)
    #expect(record.stages.map(\.stage) == [.transcript])
    #expect(record.stages.first?.result == .skipped)
    #expect(postProcessorExports(session).isEmpty)
    #expect(try postProcessorRecordOnDisk(session).state == .skipped)
}

@Test(.timeLimit(.minutes(1)))
func cancelledRunRecordsFailureAndPublishesNothing() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let gated = GatedDiarizer(postProcessorFake())
    let task = Task { try await postProcessor(gated).run(session: session, lease: nil) }
    #expect(await postProcessorEventually { gated.isWaiting })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let record = try postProcessorRecordOnDisk(session)
    #expect(record.state == .failed)
    #expect(record.message == "Post-processing was cancelled.")
    #expect(try SessionSpeakerStore.readHead(session: session) == nil)
    #expect(postProcessorExports(session).isEmpty)
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))
    #expect(try !SessionArchive.isProcessing(at: session))
}

// MARK: - Starting

@Test(.timeLimit(.minutes(1)))
func secondProcessorRefusedWhileLeaseHeld() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let error = await #expect(throws: HolosError.self) {
        try await postProcessor().run(session: session, lease: nil)
    }
    guard case .unavailable? = error else {
        Issue.record("Expected unavailable, got \(String(describing: error))")
        return
    }
    #expect(!SessionFixtures.exists(SessionPaths.postprocess(session)))
}

@Test(.timeLimit(.minutes(1)))
func usesGivenLease() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let record = try await postProcessor().run(session: session, lease: lease)
    #expect(record.state == .succeeded)
    #expect(try SessionArchive.isProcessing(at: session), "The caller still holds its lease.")
    // Another run under the same lease works (recover → rebuild → post-process under one lease, PR3).
    #expect(try await postProcessor(options: PostProcessingOptions(force: true))
        .run(session: session, lease: lease).state == .succeeded)
    lease.release()
    #expect(try !SessionArchive.isProcessing(at: session))
}

@Test(.timeLimit(.minutes(1)))
func refusesActiveRecording() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let recording = try SessionArchive.create(root: temp.url, name: "Live", source: .microphone, locale: "en-CA",
                                              backend: .speech)
    let error = await #expect(throws: HolosError.self) {
        try await postProcessor().run(session: recording.directory, lease: nil)
    }
    #expect(error?.errorDescription?.contains("still recording") == true)
    #expect(!SessionFixtures.exists(SessionPaths.postprocess(recording.directory)))
    try await recording.finish(status: ArchiveStatus.complete)
}

// MARK: - holos session diarize

@Test(.timeLimit(.minutes(1)))
func diarizeAdoptsInheritedLease() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    // The parent holds the lease and hands its descriptor over (a dup shares the open file description, as the
    // child's fd 3 does), closing its own copy without unlocking.
    let parent = try SessionArchive.acquireProcessingLease(at: session)
    let inherited = try parent.handOff { Darwin.dup($0) }
    #expect(try SessionArchive.isProcessing(at: session))
    let gated = GatedDiarizer(postProcessorFake())
    let request = SessionDiarizeCommand.Request(session: session, afterRecording: true, leaseDescriptor: inherited)
    let task = Task { try await SessionDiarizeCommand.run(request, diarizer: gated, freeSpace: FixedFreeSpace(.max)) }
    #expect(await postProcessorEventually { gated.isWaiting })
    #expect(try SessionArchive.isProcessing(at: session), "The adopted lease is held while post-processing runs.")
    #expect(throws: HolosError.self) { try SessionArchive.acquireProcessingLease(at: session, retry: .zero) }
    gated.open()
    let outcome = try await task.value
    #expect(outcome.record.state == .succeeded)
    #expect(outcome.exitCode == 0)
    #expect(outcome.summary.hasPrefix("Labelled 2 speakers in 4 turns (run "))
    #expect(outcome.summary.hasSuffix("Exports: \(SessionPaths.exports(session).path)"))
    #expect(try !SessionArchive.isProcessing(at: session), "The inherited descriptor is closed at the end.")
}

@Test(.timeLimit(.minutes(1)))
func diarizeRefusesForeignLeaseFd() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let (other, _) = try await postProcessorSession(in: temp.url)
    let otherLease = try SessionArchive.acquireProcessingLease(at: other)
    let inherited = try otherLease.handOff { Darwin.dup($0) }
    defer { Darwin.close(inherited) }
    let before = SessionFixtures.files(in: session)
    let request = SessionDiarizeCommand.Request(session: session, afterRecording: true, leaseDescriptor: inherited)
    let error = await #expect(throws: HolosError.self) {
        try await SessionDiarizeCommand.run(request, diarizer: postProcessorFake(), freeSpace: FixedFreeSpace(.max))
    }
    #expect(error?.errorDescription == "The inherited lock is not this session's processing lease.")
    #expect(SessionFixtures.files(in: session) == before, "Nothing changes.")
    #expect(try SessionArchive.isProcessing(at: other), "The other session's lease is untouched.")
    #expect(try !SessionArchive.isProcessing(at: session))
}

@Test(.timeLimit(.minutes(1)))
func diarizeWithoutModelsChangesNothing() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    let before = SessionFixtures.files(in: session)
    let error = await #expect(throws: HolosError.self) {
        try await SessionDiarizeCommand.run(SessionDiarizeCommand.Request(session: session), diarizer: nil)
    }
    #expect(error?.errorDescription == SpeakerAnalysis.modelsMissing)
    #expect(SessionFixtures.files(in: session) == before)
    #expect(!SessionFixtures.exists(session.appendingPathComponent(".processing.lock")))

    // After a recording, a session without models still gets speaker-less exports (exit 0).
    let outcome = try await SessionDiarizeCommand.run(
        SessionDiarizeCommand.Request(session: session, afterRecording: true), diarizer: nil)
    #expect(outcome.record.state == .succeeded)
    #expect(outcome.exitCode == 0)
    #expect(outcome.summary.hasPrefix("No speaker labels: speaker models are not installed."))
    #expect(postProcessorExports(session) == ["md", "json", "txt"])
}

@Test(.timeLimit(.minutes(1)))
func diarizeExitCodesFollowTheState() async throws {
    #expect(SessionDiarizeCommand.exitCode(.succeeded) == 0)
    #expect(SessionDiarizeCommand.exitCode(.partial) == 3)
    #expect(SessionDiarizeCommand.exitCode(.failed) == 1)
    #expect(SessionDiarizeCommand.exitCode(.skipped) == 1)
    #expect(SessionDiarizeCommand.exitCode(PostProcessingState("somethingNew")) == 1)

    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, _) = try await postProcessorSession(in: temp.url)
    _ = try await SessionDiarizeCommand.run(SessionDiarizeCommand.Request(session: session),
                                            diarizer: postProcessorFake(), freeSpace: FixedFreeSpace(.max))
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Jim")], session: session)
    let refused = try await SessionDiarizeCommand.run(SessionDiarizeCommand.Request(session: session),
                                                      diarizer: postProcessorFake(), freeSpace: FixedFreeSpace(.max))
    #expect(refused.exitCode == 3)
    #expect(refused.summary.hasPrefix(SpeakerAnalysis.editedHead))
}

@Test(.timeLimit(.minutes(1)))
func diarizeAfterRecordingWaitsForTheWriter() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let recording = try SessionArchive.create(root: temp.url, name: "Live", source: .microphone, locale: "en-CA",
                                              backend: .speech)
    let request = SessionDiarizeCommand.Request(session: recording.directory, afterRecording: true,
                                                writerWait: .milliseconds(200))
    let error = await #expect(throws: HolosError.self) {
        try await SessionDiarizeCommand.run(request, diarizer: postProcessorFake())
    }
    guard case .unavailable? = error else {
        Issue.record("Expected unavailable, got \(String(describing: error))")
        return
    }
    try await recording.finish(status: ArchiveStatus.complete)
    let outcome = try await SessionDiarizeCommand.run(request, diarizer: postProcessorFake())
    #expect(outcome.record.state == .skipped, "No transcript: nothing to label.")
    #expect(outcome.exitCode == 1)
}
