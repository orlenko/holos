import Accelerate
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The acoustic echo mask in post-processing and `voiceislocal session echo-analyze` (docs/meeting-design.md §5.11),
// on synthetic audio only.

// MARK: - Synthetic call audio

/// SplitMix64: deterministic noise.
private struct Noise {
    var state: UInt64

    mutating func uniform() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 52)) - 1
    }
}

private let rate = 16_000

/// Band-limited noise with a 4 Hz syllable envelope inside `intervals`, at RMS `level` while it speaks.
private func speech(seconds: Double, intervals: [(Double, Double)], level: Float, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    var out = [Float](repeating: 0, count: Int(seconds * Double(rate)))
    var low: Float = 0
    var previous: Float = 0
    var sum = 0.0
    var count = 0
    for (start, end) in intervals {
        for index in Int(start * Double(rate))..<min(out.count, Int(end * Double(rate))) {
            let white = noise.uniform() + noise.uniform() + noise.uniform()
            low += 0.6 * (white - previous - low)
            previous = white
            let envelope = Float(0.55 + 0.45 * sin(2 * Double.pi * 4 * Double(index) / Double(rate)))
            out[index] = low * envelope
            sum += Double(out[index] * out[index])
            count += 1
        }
    }
    let factor = level / Float((sum / Double(max(1, count))).squareRoot())
    return out.map { $0 * factor }
}

/// `signal` delayed by `delay` seconds through a direct path and 30 ms of decaying reflections, times `gain`.
private func roomEcho(_ signal: [Float], delay: Double, gain: Float) -> [Float] {
    var noise = Noise(state: 9)
    let response = (0..<480).map { $0 == 0 ? Float(1) : 0.4 * Float(exp(-Double($0) / 80)) * noise.uniform() }
    let input = [Float](repeating: 0, count: Int(delay * Double(rate)) + response.count - 1) + signal
    var out = [Float](repeating: 0, count: signal.count)
    response.withUnsafeBufferPointer { filter in
        vDSP_conv(input, 1, filter.baseAddress! + response.count - 1, -1, &out, 1, vDSP_Length(signal.count),
                  vDSP_Length(response.count))
    }
    return out.map { $0 * gain }
}

/// 45 s of a call. The far end talks in `systemTalks`; with `echo`, the microphone hears it 46 ms later through the
/// laptop speakers; the user talks in `ownTalks`, while the call is quiet.
private enum CallAudio {
    static let seconds = 45.0
    static let systemTalks = [(1.0, 7.0), (10.0, 16.0), (20.0, 26.0), (30.0, 36.0), (39.0, 44.0)]
    static let ownTalks = [(7.6, 9.4), (16.5, 19.5), (26.5, 29.5)]

    static func tracks(echo: Bool) -> [String: [Float]] {
        let system = speech(seconds: seconds, intervals: systemTalks, level: 0.05, seed: 1)
        let own = speech(seconds: seconds, intervals: ownTalks, level: 0.01, seed: 2)
        var hiss = Noise(state: 3)
        var mic = own.map { $0 + hiss.uniform() * 1e-4 }
        if echo {
            for (index, value) in roomEcho(system, delay: 0.046, gain: 0.5).enumerated() { mic[index] += value }
        }
        return ["mic": mic, "system": system]
    }
}

/// A finished call whose tracks hold `audio` (16 kHz), with `transcript` saved as current.
private func callSession(in root: URL, audio: [String: [Float]], transcript: Transcript, othersInRoom: Bool = false,
                         mode: MeetingMode = .call) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Fixture call", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: mode, othersInRoom: othersInRoom,
                                         createdAt: SessionFixtures.date),
                             to: SessionPaths.meetingInfo(archive.directory))
    let writer = AudioChunkWriter(archive: archive)
    for (track, samples) in audio.sorted(by: { $0.key < $1.key }) {
        let frame = try PCMFrame(samples: samples, sampleRate: 16_000, channels: 1, startTime: 0)
        try await writer.append(CapturedAudio(track: track, frame: frame))
    }
    try await writer.finish()
    try await archive.saveTranscript(transcript, writeLegacyExports: false)
    try await archive.finish(status: ArchiveStatus.complete)
    return archive.directory
}

/// The call's transcript: system words through each far-end turn, microphone words that are echo (heard as other
/// words than the system's, so the text filter keeps them) in 11–14 s and 31–34 s, and the user's own words.
private struct CallTranscript {
    let transcript: Transcript
    let echoSegments: [TranscriptSegment]
    let ownSegments: [TranscriptSegment]

    init() {
        let system = CallAudio.systemTalks.enumerated().map { index, talk in
            SessionFixtures.segment((0..<8).map { "far\(index)w\($0)" }, track: "system", start: talk.0 + 0.5,
                                    wordSeconds: 0.5)
        }
        echoSegments = [11.0, 31.0].enumerated().map { index, start in
            SessionFixtures.segment((0..<6).map { "heard\(index)w\($0)" }, track: "mic", start: start, wordSeconds: 0.5)
        }
        ownSegments = CallAudio.ownTalks.enumerated().map { index, talk in
            SessionFixtures.segment((0..<3).map { "own\(index)w\($0)" }, track: "mic", start: talk.0 + 0.2,
                                    wordSeconds: 0.45)
        }
        transcript = SessionFixtures.transcript(system + echoSegments + ownSegments)
    }

    var echoSpans: [WordSpan] { echoSegments.map { WordSpan(segmentID: $0.id, first: 0, end: $0.words.count) } }
}

private func systemDiarizer() -> FakeDiarizer {
    FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput(turnSeconds: 5, duration: CallAudio.seconds)])
}

// MARK: - Post-processing

@Test(.timeLimit(.minutes(2)))
func callPostProcessingDropsAcousticEchoAndSavesTheMask() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.stages.map(\.stage) == [.transcript, .render, .echo, .diarize, .align, .export])
    #expect(record.stages.first { $0.stage == .echo }?.result == .succeeded)

    let manifest = try SessionArchive.readManifest(at: session)
    let stored = try #require(try EchoMaskStore.current(session: session, manifest: manifest))
    #expect(stored.record.verdict == .echo)
    #expect(abs((stored.record.delay?.milliseconds(at: 20) ?? 0) - 46) < 1)
    #expect(stored.mask != nil)
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))

    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords == [DroppedWords(spans: call.echoSpans, reason: EchoFilter.acousticReason)])
    let mine = run.turns.filter { $0.track == "mic" }
    #expect(Set(mine.flatMap(\.spans).map(\.segmentID)) == Set(call.ownSegments.map(\.id)))
    #expect(mine.allSatisfy { $0.speakerID == "mic:me" })
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(!markdown.contains("heard0w0"))
    #expect(markdown.contains("own0w0"))

    // A relabel of the same audio reuses the saved mask: no echo stage, the same drops.
    let again = try await MeetingPostProcessor(diarizer: systemDiarizer(), options: .init(force: true),
                                               freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    #expect(again.stages.map(\.stage) == [.transcript, .render, .diarize, .align, .export])
    let rerun = try SessionSpeakerStore.readRun(id: try #require(again.runID), session: session)
    #expect(rerun.droppedWords == run.droppedWords)
}

@Test(.timeLimit(.minutes(2)))
func headphonesCallKeepsEveryMicrophoneWord() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: false), transcript: call.transcript)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    let manifest = try SessionArchive.readManifest(at: session)
    let stored = try #require(try EchoMaskStore.current(session: session, manifest: manifest))
    #expect(stored.record.verdict == .noEcho)
    #expect(stored.mask == nil)
    #expect(!SessionFixtures.exists(EchoMaskStore.framesURL(session)))
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords.isEmpty)
    #expect(run.turns.filter { $0.track == "mic" }.flatMap(\.spans).count
        == call.echoSegments.count + call.ownSegments.count)
}

@Test(.timeLimit(.minutes(2)))
func anUnreadableMicrophoneCostsOnlyTheMask() async throws {
    // The microphone is "Me" (not diarized), so only the echo stage reads it; its audio is gone.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    for chunk in manifest.chunks where chunk.track == "mic" {
        try FileManager.default.removeItem(at: session.appendingPathComponent(chunk.relativePath))
    }
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.stages.first { $0.stage == .echo }?.result == .failed)
    #expect(record.stages.first { $0.stage == .align }?.result == .succeeded)
    #expect(!SessionFixtures.exists(EchoMaskStore.recordURL(session)))
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords.isEmpty)
    // The labels were made, but without the echo analysis they are not current: Recover runs it again.
    #expect(record.state == .succeeded)
    #expect(try SessionRecoveryCommand.currentLabels(session, transcriptID: call.transcript.id, canLabel: true) == nil)
}

@Test(.timeLimit(.minutes(2)))
func anEchoAnalysisThatFailedIsRetriedAfterTheLabelsAreEdited() async throws {
    // The first run cannot read the microphone, so its echo is not found; the user then names a speaker. The next run
    // keeps the edited labels but takes the echo out of them, keeping the name.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let micChunks = manifest.chunks.filter { $0.track == "mic" }.map { session.appendingPathComponent($0.relativePath) }
    for chunk in micChunks {
        try FileManager.default.moveItem(at: chunk, to: chunk.appendingPathExtension("away"))
    }
    let first = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(first.stages.first { $0.stage == .echo }?.result == .failed)
    for chunk in micChunks {
        try FileManager.default.moveItem(at: chunk.appendingPathExtension("away"), to: chunk)
    }
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Person A")], session: session)

    let second = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(second.state == .partial)
    #expect(second.stages.first { $0.stage == .echo }?.result == .succeeded)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.run?.id == second.runID)
    #expect(snapshot.run?.droppedWords == [DroppedWords(spans: call.echoSpans, reason: EchoFilter.acousticReason)])
    #expect(snapshot.projection?.speakers.first { $0.id == "system:S1" }?.name == "Person A")
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard0w0"))
    // Settled now: Recover leaves it.
    #expect(try SessionRecoveryCommand.currentLabels(session, transcriptID: call.transcript.id, canLabel: true) != nil)
    // And with the analysis saved, a later run finds nothing more to do.
    let third = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(third.runID == second.runID)
    #expect(!third.stages.contains { $0.stage == .echo })
}

@Test(.timeLimit(.minutes(2)))
func recoverRetriesAnEchoAnalysisOfACompleteMeeting() async throws {
    // A complete recording (nothing to rebuild) whose echo analysis failed: Recover labels it again so the analysis
    // runs, instead of calling its labels up to date.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let micChunks = manifest.chunks.filter { $0.track == "mic" }.map { session.appendingPathComponent($0.relativePath) }
    for chunk in micChunks {
        try FileManager.default.moveItem(at: chunk, to: chunk.appendingPathExtension("away"))
    }
    let first = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(first.stages.first { $0.stage == .echo }?.result == .failed)
    for chunk in micChunks {
        try FileManager.default.moveItem(at: chunk.appendingPathExtension("away"), to: chunk)
    }
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.complete)

    let outcome = try await SessionRecoveryCommand.run(.init(session: session), diarizer: systemDiarizer(),
                                                       freeSpace: FixedFreeSpace(.max))
    let record = try #require(outcome.postProcessing)
    #expect(record.stages.first { $0.stage == .echo }?.result == .succeeded)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords == [DroppedWords(spans: call.echoSpans, reason: EchoFilter.acousticReason)])
    // Settled: a second Recover leaves the labels alone.
    let again = try await SessionRecoveryCommand.run(.init(session: session), diarizer: systemDiarizer(),
                                                     freeSpace: FixedFreeSpace(.max))
    #expect(again.postProcessing == nil)
}

/// Diarizes like `FakeDiarizer` and, while it does, has the user name a speaker in the labels in place (an edit landing
/// during a relabel).
private struct EditingDiarizer: SpeakerDiarizer {
    let session: URL
    let inner: FakeDiarizer

    func engineInfo() async throws -> DiarizationEngineInfo { try await inner.engineInfo() }

    func diarize(_ request: DiarizationRequest,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput {
        try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Person A")], session: session)
        return try await inner.diarize(request, progress: progress)
    }
}

@Test(.timeLimit(.minutes(2)))
func anEditDuringTheRelabelStillGetsTheEchoTakenOut() async throws {
    // Labels without edits are being made again; an edit lands meanwhile, so the new run is not published. The echo
    // found in this pass still leaves the edited labels, and the record names the head that was published.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let old = try SessionFixtures.writeHeadRun(
        session: session, transcript: call.transcript,
        outputs: ["system": SessionFixtures.alternatingOutput(turnSeconds: 5, duration: CallAudio.seconds)],
        policies: ["mic": .channel(speakerID: "mic:me", displayName: "Me")])
    let diarizer = EditingDiarizer(session: session, inner: systemDiarizer())
    let record = try await MeetingPostProcessor(diarizer: diarizer, freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.stages.first { $0.stage == .align }?.result == .skipped)
    #expect(record.stages.first { $0.stage == .echo }?.result == .succeeded)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let head = try #require(snapshot.run)
    #expect(head.id != old.id)
    #expect(record.runID == head.id)
    #expect(try SessionFiles.postProcessingRecord(session: session)?.runID == head.id)
    #expect(head.droppedWords.contains(DroppedWords(spans: call.echoSpans, reason: EchoFilter.acousticReason)))
    #expect(snapshot.projection?.speakers.first { $0.id == "system:S1" }?.name == "Person A")
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard0w0"))
}

@Test(.timeLimit(.minutes(2)))
func anEchoAnalysisPutOffForDiskSpaceIsNotSettled() async throws {
    // No track to diarize and a stop for low disk space: the analysis is put off, and Recover tries again later.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let micOnly = SessionFixtures.transcript(call.echoSegments + call.ownSegments)
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: micOnly)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), options: .init(stopReason: .diskLow),
                                                freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    #expect(record.stages.first { $0.stage == .echo }?.result == .skipped)
    #expect(!SessionFixtures.exists(EchoMaskStore.recordURL(session)))
    #expect(try SessionRecoveryCommand.currentLabels(session, transcriptID: micOnly.id, canLabel: true) == nil)
}

@Test(.timeLimit(.minutes(2)))
func damagedSummaryCountsInTheRecordAreNotTrusted() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true),
                                        transcript: CallTranscript().transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let mask = try #require(AcousticEchoMask(classes: [1, 1, 2], echoLevels: [0, 0, 0]))
    let record = EchoMaskRecord(sessionID: manifest.id, audio: EchoMaskStore.audioKey(manifest: manifest),
                                verdict: .echo,
                                frames: .init(count: 3, hopSeconds: 0.016, firstCentreSeconds: 0.032,
                                              sha256: SessionExports.sha256(mask.bytes), echo: .max, local: .max))
    try EchoMaskStore.write(record, mask: mask, session: session)
    let stored = try #require(try EchoMaskStore.current(session: session, manifest: manifest))
    #expect(stored.record.frames?.echo == 2)
    #expect(stored.record.frames?.local == 1)
    #expect(EchoAnalysisStage.message(stored.record).contains("67 %"))
    // Even a record whose counts were never checked makes a sentence, not a trap.
    #expect(!EchoAnalysisStage.message(record).isEmpty)
    var negative = record
    negative.frames?.echo = -5
    #expect(!EchoAnalysisStage.message(negative).isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func echoIsFoundWhenNoTrackNeedsDiarizing() async throws {
    // The microphone is "Me" and the system track has no words (its recognition failed): no track is diarized, and
    // the microphone's echo is still found.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let micOnly = SessionFixtures.transcript(call.echoSegments + call.ownSegments)
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: micOnly)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.stages.first { $0.stage == .echo }?.result == .succeeded)
    #expect(record.stages.first { $0.stage == .diarize }?.result == .skipped)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords == [DroppedWords(spans: call.echoSpans, reason: EchoFilter.acousticReason)])
    #expect(try SessionRecoveryCommand.currentLabels(session, transcriptID: micOnly.id, canLabel: true) != nil)
}

@Test(.timeLimit(.minutes(2)))
func callWithoutSystemAudioSavesNoEchoWithoutAStage() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let mic = SessionFixtures.segment(["only", "me", "here"], track: "mic", start: 2)
    let session = try await callSession(in: temp.url, audio: ["mic": CallAudio.tracks(echo: false)["mic"]!],
                                        transcript: SessionFixtures.transcript([mic]), othersInRoom: true)
    let record = try await MeetingPostProcessor(diarizer: FakeDiarizer(outputs: [:]), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(!record.stages.contains { $0.stage == .echo })
    let manifest = try SessionArchive.readManifest(at: session)
    let stored = try #require(try EchoMaskStore.current(session: session, manifest: manifest))
    #expect(stored.record.verdict == .noSystemAudio)
    #expect(stored.record.audio.keys.sorted() == ["mic"])
}

@Test(.timeLimit(.minutes(2)))
func aMaskOfOtherAudioOrAnOlderVersionIsNotUsedAndANewerOneIsKept() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let mask = try #require(AcousticEchoMask(classes: [1, 1, 2], echoLevels: [0, 0, 0]))
    let key = EchoMaskStore.audioKey(manifest: manifest)
    func record(audio: [String: String], version: Int = EchoAnalysis.version) -> EchoMaskRecord {
        EchoMaskRecord(sessionID: manifest.id, analysisVersion: version, audio: audio, verdict: .echo,
                       frames: .init(count: 3, hopSeconds: 0.016, firstCentreSeconds: 0.032,
                                     sha256: SessionExports.sha256(mask.bytes), echo: 2, local: 1))
    }
    try EchoMaskStore.write(record(audio: key), mask: mask, session: session)
    #expect(try EchoMaskStore.current(session: session, manifest: manifest)?.mask == mask)
    var otherAudio = key
    otherAudio["system"] = String(repeating: "0", count: 64)
    try EchoMaskStore.write(record(audio: otherAudio), mask: mask, session: session)
    #expect(try EchoMaskStore.current(session: session, manifest: manifest) == nil)
    // An older analysis is made again; a newer one is refused, never read as out of date.
    try EchoMaskStore.write(record(audio: key, version: EchoAnalysis.version - 1), mask: mask, session: session)
    #expect(try EchoMaskStore.current(session: session, manifest: manifest) == nil)
    try EchoMaskStore.write(record(audio: key, version: EchoAnalysis.version + 1), mask: mask, session: session)
    #expect(throws: HolosError.self) { try EchoMaskStore.current(session: session, manifest: manifest) }
    // Even with a verdict this build does not know.
    let unknownVerdict = SessionFixtures.text(EchoMaskStore.recordURL(session))
        .replacingOccurrences(of: "\"verdict\" : \"echo\"", with: "\"verdict\" : \"echoTwice\"")
    #expect(unknownVerdict.contains("echoTwice"))
    try AtomicFile.write(Data(unknownVerdict.utf8), to: EchoMaskStore.recordURL(session))
    #expect(throws: HolosError.self) { try EchoMaskStore.current(session: session, manifest: manifest) }
    // Post-processing leaves it as it is and labels without a mask.
    let newerBytes = try Data(contentsOf: EchoMaskStore.recordURL(session))
    let processed = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(!processed.stages.contains { $0.stage == .echo })
    #expect(try Data(contentsOf: EchoMaskStore.recordURL(session)) == newerBytes)
    #expect(try SessionSpeakerStore.readRun(id: try #require(processed.runID), session: session).droppedWords.isEmpty)
    // A frames file that is not the one the record names.
    try EchoMaskStore.write(record(audio: key), mask: mask, session: session)
    try AtomicFile.write(Data([1, 1, 1, 0, 0, 0]), to: EchoMaskStore.framesURL(session))
    #expect(try EchoMaskStore.current(session: session, manifest: manifest) == nil)
    // A newer record is refused, never read as missing.
    var newer = record(audio: key)
    newer.schemaVersion = EchoMaskRecord.currentVersion + 1
    try AtomicFile.writeJSON(newer, to: EchoMaskStore.recordURL(session))
    #expect(throws: HolosError.self) { try EchoMaskStore.current(session: session, manifest: manifest) }
}

// MARK: - echo-analyze

/// A call labelled before the analysis existed: others in the room, so the microphone is diarized; its echo and the
/// user's words are two clusters.
private func labelledOldCall(in root: URL) async throws -> (session: URL, call: CallTranscript, run: DiarizationRun) {
    let call = CallTranscript()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let session = try await callSession(in: root, audio: CallAudio.tracks(echo: true), transcript: call.transcript,
                                        othersInRoom: true)
    let micOutput = DiarizerOutput(
        segments: call.echoSegments.map { RawDiarizationSegment(speaker: "S1", start: $0.start, end: $0.end) }
            + call.ownSegments.map { RawDiarizationSegment(speaker: "S2", start: $0.start, end: $0.end) },
        centroids: [:], windows: [], processingSeconds: 0)
    let run = try SessionFixtures.writeHeadRun(
        session: session, transcript: call.transcript,
        outputs: ["mic": micOutput, "system": SessionFixtures.alternatingOutput(turnSeconds: 5,
                                                                                duration: CallAudio.seconds)])
    return (session, call, run)
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeRebuildsAnOldCallKeepingItsEdits() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, call, run) = try await labelledOldCall(in: temp.url)
    #expect(run.speakers.map(\.id).contains("mic:S1"))
    let ownTurn = try #require(run.turns.first { $0.spans.first?.segmentID == call.ownSegments[1].id })
    let systemTurn = try #require(run.turns.first { $0.track == "system" })
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S2", name: "Person A")], session: session)
    try SessionFixtures.appendEdits([.reassignTurns(turnIDs: [systemTurn.id], to: "system:S2")], session: session)
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: [ownTurn.id])], session: session)
    let transcriptBefore = try SessionFiles.currentTranscript(session: session)

    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(outcome.analysed)
    #expect(outcome.verdict == .echo)
    #expect(outcome.keptEdits == 3)
    #expect(outcome.droppedEdits == 0)
    #expect(outcome.acousticEchoWords == call.echoSegments.reduce(0) { $0 + $1.words.count })
    #expect(outcome.microphoneTurnsAfter == call.ownSegments.count)
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))

    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let head = try #require(snapshot.run)
    #expect(head.id == outcome.runID)
    #expect(head.transcriptID == run.transcriptID)
    #expect(try SessionFiles.currentTranscript(session: session) == transcriptBefore)
    // The echo cluster is gone; the user's cluster keeps its name, the reassigned system turn its speaker, the
    // excluded turn its exclusion.
    #expect(!head.turns.contains { $0.speakerID == "mic:S1" })
    #expect(snapshot.projection?.speakers.contains { $0.id == "mic:S1" } == false)
    let view = try #require(snapshot.projection)
    #expect(view.staleEdits.isEmpty)
    #expect(view.speakers.first { $0.id == "mic:S2" }?.name == "Person A")
    #expect(view.turns.first { $0.spans == systemTurn.spans }?.speakerID == "system:S2")
    #expect(view.turns.first { $0.spans == ownTurn.spans }?.excludedFromEnrollment == true)
    #expect(head.droppedWords == [DroppedWords(spans: call.echoSpans, reason: EchoFilter.acousticReason)])
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard1w2"))

    // Again: the saved analysis is used and the labels already match it.
    let again = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(!again.analysed)
    #expect(again.runID == nil)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == head.id)
}

/// Saves voice suggestions for `runID`: system:S1 may be MARIA, system:S2 may be JIM.
private func writeSuggestions(runID: String, session: URL) throws {
    let matches = [("system:S1", "MARIA", "Maria"), ("system:S2", "JIM", "Jim")].map {
        SpeakerMatch(speakerID: $0.0, profileID: $0.1, profileName: $0.2, distance: 0.2, tier: .possible)
    }
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: runID, embeddingModel: DiarizationEngineInfo.fake.embeddingModel,
                              thresholds: SpeakerRecognizer.defaultThresholds, matches: matches),
            session: session)
    }
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeCarriesSuggestionsOnlyForPeopleTheStoreHolds() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
    // JIM was forgotten: the store holds MARIA only.
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [SpeakerProfile(id: "MARIA", displayName: "Maria")]
    }
    let (session, _, run) = try await labelledOldCall(in: temp.url.appendingPathComponent("a", isDirectory: true))
    try writeSuggestions(runID: run.id, session: session)
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), profiles: store,
                                                          freeSpace: FixedFreeSpace(.max))
    let newRun = try #require(outcome.runID)
    let carried = try #require(try SessionSpeakerStore.readRecognition(runID: newRun, session: session))
    #expect(carried.runID == newRun)
    #expect(carried.matches.map(\.profileID) == ["MARIA"])

    // With Remember voices off, nothing is copied.
    try store.update { $0.rememberVoices = false }
    let (off, _, offRun) = try await labelledOldCall(in: temp.url.appendingPathComponent("b", isDirectory: true))
    try writeSuggestions(runID: offRun.id, session: off)
    let offOutcome = try await SessionEchoAnalyzeCommand.run(.init(session: off), profiles: store,
                                                             freeSpace: FixedFreeSpace(.max))
    #expect(try SessionSpeakerStore.readRecognition(runID: try #require(offOutcome.runID), session: off) == nil)
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeReplacesNothingWhenTheJournalChangesMeanwhile() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    // A torn line, then a complete line this build cannot read (a newer schema), each written while it runs.
    let lines = [Data("{\"schemaVersion\":1,\"id\":\"TORN".utf8),
                 Data("{\"schemaVersion\":99,\"id\":\"NEWER\",\"baseRunID\":\"X\"}\n".utf8)]
    for (index, line) in lines.enumerated() {
        let (session, _, run) = try await labelledOldCall(in: temp.url.appendingPathComponent("\(index)",
                                                                                             isDirectory: true))
        try SessionFixtures.appendEdits([.rename(speakerID: "mic:S2", name: "Person A")], session: session)
        let journalURL = SessionPaths.edits(session)
        let before = try Data(contentsOf: journalURL)
        await #expect(throws: HolosError.self) {
            try await SessionEchoAnalyzeCommand.$beforePublish.withValue({
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }) {
                _ = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
            }
        }
        #expect(try SessionSpeakerStore.readHead(session: session)?.runID == run.id)
        #expect(try Data(contentsOf: journalURL) == before + line)
    }
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeWritesTheFilesAnEarlierRunCouldNot() async throws {
    // The first run publishes the new labels but cannot write the transcript files (a file stands where the exports
    // folder goes). The next run finds the labels up to date and still writes the files.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, run) = try await labelledOldCall(in: temp.url)
    let exports = SessionPaths.exports(session)
    try? FileManager.default.removeItem(at: exports)
    try Data("in the way".utf8).write(to: exports)
    let first = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(first.runID != nil)
    #expect(first.summary.contains("could not be rewritten"))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID != run.id)

    try FileManager.default.removeItem(at: exports)
    let second = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(second.runID == nil)
    #expect(!second.summary.contains("could not be rewritten"))
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.contains("own0w0"))
    #expect(!markdown.contains("heard0w0"))
}

@Test func echoAnalyzeLeavesAnInPersonMeetingAlone() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, run) = try await SessionFixtures.labelledSession(in: temp.url, track: "mic")
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == nil)
    #expect(outcome.runID == nil)
    #expect(!SessionFixtures.exists(EchoMaskStore.directory(session)))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == run.id)
}
