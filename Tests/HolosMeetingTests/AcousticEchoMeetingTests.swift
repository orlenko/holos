import Accelerate
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The acoustic echo analysis in post-processing, Recover and `voiceislocal session echo-analyze`, and the labels'
// view that hides the echo (docs/meeting-design.md §5.11), on synthetic audio only. Stored runs never hold it.

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
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    var echoSegmentIDs: Set<String> { Set(echoSegments.map(\.id)) }
    var ownSegmentIDs: Set<String> { Set(ownSegments.map(\.id)) }
}

private func systemDiarizer() -> FakeDiarizer {
    FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput(turnSeconds: 5, duration: CallAudio.seconds)])
}

/// The microphone segments of the turns the labels show now.
private func shownMicSegments(_ session: URL) throws -> Set<String> {
    let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
    return Set(view.turns.filter { $0.track == "mic" }.flatMap(\.spans).map(\.segmentID))
}

/// Every file under speakers/, for "the stored labels did not change" checks.
private func speakerFiles(_ session: URL) -> [String: Data] {
    SessionFixtures.files(in: session.appendingPathComponent("speakers", isDirectory: true))
}

private func moveMicrophoneAudio(_ session: URL, away: Bool) throws {
    let manifest = try SessionArchive.readManifest(at: session)
    for chunk in manifest.chunks where chunk.track == "mic" {
        let url = session.appendingPathComponent(chunk.relativePath)
        let aside = url.appendingPathExtension("away")
        if away {
            try FileManager.default.moveItem(at: url, to: aside)
        } else {
            try FileManager.default.moveItem(at: aside, to: url)
        }
    }
}

// MARK: - Post-processing

@Test(.timeLimit(.minutes(2)))
func postProcessingSavesTheMaskAndTheViewHidesTheEcho() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.stages.map(\.stage) == [.transcript, .render, .echo, .diarize, .align, .export])
    let manifest = try SessionArchive.readManifest(at: session)
    let stored = try #require(try EchoMaskStore.current(session: session, manifest: manifest))
    #expect(stored.record.verdict == .echo)
    #expect(abs((stored.record.delay?.milliseconds(at: 20) ?? 0) - 46) < 1)
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))

    // The stored run is what it always was: its turns hold the echo; only the view hides it.
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords.isEmpty)
    #expect(Set(run.turns.filter { $0.track == "mic" }.flatMap(\.spans).map(\.segmentID))
        == call.echoSegmentIDs.union(call.ownSegmentIDs))
    #expect(try shownMicSegments(session) == call.ownSegmentIDs)

    // The transcript files are the view: written from it, and the same as rendering it now.
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(!markdown.contains("heard0w0"))
    #expect(markdown.contains("own0w0"))
    let rendered = try SessionExports.render(.md, session: session, profileNames: [:], applyRecognition: true)
    #expect(String(decoding: rendered, as: UTF8.self) == markdown)

    // A relabel of the same audio uses the saved analysis: no echo stage.
    let again = try await MeetingPostProcessor(diarizer: systemDiarizer(), options: .init(force: true),
                                               freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    #expect(again.stages.map(\.stage) == [.transcript, .render, .diarize, .align, .export])
    #expect(try shownMicSegments(session) == call.ownSegmentIDs)
}

@Test(.timeLimit(.minutes(2)))
func headphonesCallShowsEveryMicrophoneWord() async throws {
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
    #expect(!EchoAnalysisStage.needed(session: session), "A saved no-echo verdict counts as done.")
    #expect(try shownMicSegments(session) == call.echoSegmentIDs.union(call.ownSegmentIDs))
}

@Test(.timeLimit(.minutes(2)))
func aCallWithoutSystemAudioNeedsNoAnalysis() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let mic = SessionFixtures.segment(["only", "me", "here"], track: "mic", start: 2)
    let session = try await callSession(in: temp.url, audio: ["mic": CallAudio.tracks(echo: false)["mic"]!],
                                        transcript: SessionFixtures.transcript([mic]), othersInRoom: true)
    #expect(!EchoAnalysisStage.needed(session: session))
    let record = try await MeetingPostProcessor(diarizer: FakeDiarizer(outputs: [:]), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(!record.stages.contains { $0.stage == .echo })
    #expect(!SessionFixtures.exists(EchoMaskStore.directory(session)))
}

@Test(.timeLimit(.minutes(2)))
func echoIsFoundWhenNoTrackNeedsDiarizing() async throws {
    // The microphone is "Me" and the system track has no words: no track is diarized, and the echo is still found.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let micOnly = SessionFixtures.transcript(call.echoSegments + call.ownSegments)
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: micOnly)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.stages.first { $0.stage == .echo }?.result == .succeeded)
    #expect(try shownMicSegments(session) == call.ownSegmentIDs)
}

@Test(.timeLimit(.minutes(2)))
func anAnalysisThatFailedIsStillNeededAndTheNextPassMakesIt() async throws {
    // The microphone audio cannot be read: only the analysis fails, and nothing records that it is owed; the files
    // say so (no saved analysis), and the next pass makes it.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    try moveMicrophoneAudio(session, away: true)
    let first = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(first.stages.first { $0.stage == .echo }?.result == .failed)
    #expect(first.stages.first { $0.stage == .align }?.result == .succeeded)
    #expect(!SessionFixtures.exists(EchoMaskStore.recordURL(session)))
    #expect(EchoAnalysisStage.needed(session: session))
    #expect(try SessionRecoveryCommand.currentLabels(session, transcriptID: call.transcript.id, canLabel: true) != nil,
            "The labels themselves are current; the analysis is owed by the files, not by this record.")
    try moveMicrophoneAudio(session, away: false)
    let second = try await MeetingPostProcessor(diarizer: systemDiarizer(), options: .init(force: true),
                                                freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    #expect(second.stages.first { $0.stage == .echo }?.result == .succeeded)
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(try shownMicSegments(session) == call.ownSegmentIDs)
}

@Test(.timeLimit(.minutes(2)))
func editedLabelsKeepTheirFilesAndShowWithoutTheEcho() async throws {
    // Labels with an edit are kept by post-processing; the analysis is still made, and their view hides the echo
    // without a single stored file changing.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    try SessionFixtures.writeHeadRun(
        session: session, transcript: call.transcript,
        outputs: ["system": SessionFixtures.alternatingOutput(turnSeconds: 5, duration: CallAudio.seconds)],
        policies: ["mic": .channel(speakerID: "mic:me", displayName: "Me")])
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Person A")], session: session)
    let before = speakerFiles(session)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.stages.first { $0.stage == .echo }?.result == .succeeded)
    #expect(speakerFiles(session) == before)
    #expect(try shownMicSegments(session) == call.ownSegmentIDs)
    let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
    #expect(view.speakers.first { $0.id == "system:S1" }?.name == "Person A")
}

// MARK: - The mask on disk

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
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == mask)
    var otherAudio = key
    otherAudio["system"] = String(repeating: "0", count: 64)
    try EchoMaskStore.write(record(audio: otherAudio), mask: mask, session: session)
    #expect(try EchoMaskStore.current(session: session, manifest: manifest) == nil)
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == nil)
    #expect(EchoAnalysisStage.needed(session: session))
    // An older analysis is made again; a newer one is refused, never read as out of date or overwritten.
    try EchoMaskStore.write(record(audio: key, version: EchoAnalysis.version - 1), mask: mask, session: session)
    #expect(try EchoMaskStore.current(session: session, manifest: manifest) == nil)
    try EchoMaskStore.write(record(audio: key, version: EchoAnalysis.version + 1), mask: mask, session: session)
    #expect(throws: HolosError.self) { try EchoMaskStore.current(session: session, manifest: manifest) }
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == nil)
    #expect(!EchoAnalysisStage.needed(session: session), "A newer analysis is left alone.")
    // Even with a verdict this build does not know.
    let unknownVerdict = SessionFixtures.text(EchoMaskStore.recordURL(session))
        .replacingOccurrences(of: "\"verdict\" : \"echo\"", with: "\"verdict\" : \"echoTwice\"")
    #expect(unknownVerdict.contains("echoTwice"))
    try AtomicFile.write(Data(unknownVerdict.utf8), to: EchoMaskStore.recordURL(session))
    #expect(throws: HolosError.self) { try EchoMaskStore.current(session: session, manifest: manifest) }
    let newerBytes = try Data(contentsOf: EchoMaskStore.recordURL(session))
    let processed = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(!processed.stages.contains { $0.stage == .echo })
    #expect(try Data(contentsOf: EchoMaskStore.recordURL(session)) == newerBytes)
    #expect(try shownMicSegments(session) == call.echoSegmentIDs.union(call.ownSegmentIDs))
    // A frames file that is not the one the record names: damaged, so not used.
    try EchoMaskStore.write(record(audio: key), mask: mask, session: session)
    try AtomicFile.write(Data([1, 1, 1, 0, 0, 0]), to: EchoMaskStore.framesURL(session))
    #expect(try EchoMaskStore.current(session: session, manifest: manifest) == nil)
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == nil)
    // A newer schema is refused too.
    var newer = record(audio: key)
    newer.schemaVersion = EchoMaskRecord.currentVersion + 1
    try AtomicFile.writeJSON(newer, to: EchoMaskStore.recordURL(session))
    #expect(throws: HolosError.self) { try EchoMaskStore.current(session: session, manifest: manifest) }
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
    #expect(!EchoAnalysisStage.message(record).isEmpty)
    var negative = record
    negative.frames?.echo = -5
    #expect(!EchoAnalysisStage.message(negative).isEmpty)
}

// MARK: - Recover

@Test(.timeLimit(.minutes(2)))
func recoverMakesAMissingAnalysisOncePerRun() async throws {
    // A complete meeting labelled while its microphone audio could not be read, so its analysis is missing. A Recover
    // without disk space tries once and says why; the next one makes it and rewrites the transcript files; then
    // there is nothing to do.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    try moveMicrophoneAudio(session, away: true)
    _ = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    try moveMicrophoneAudio(session, away: false)
    #expect(EchoAnalysisStage.needed(session: session))

    let short = try await SessionRecoveryCommand.run(.init(session: session), diarizer: systemDiarizer(),
                                                     freeSpace: FixedFreeSpace(0))
    #expect(short.warnings.filter { $0.contains("echo was not analysed") }.count == 1)
    #expect(short.exitCode == 3)
    #expect(EchoAnalysisStage.needed(session: session))

    let outcome = try await SessionRecoveryCommand.run(.init(session: session), diarizer: systemDiarizer(),
                                                       freeSpace: FixedFreeSpace(.max))
    #expect(outcome.postProcessing == nil, "The labels were current; only the analysis was owed.")
    #expect(outcome.summary.contains("Microphone echo found"))
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard0w0"))
    let again = try await SessionRecoveryCommand.run(.init(session: session), diarizer: systemDiarizer(),
                                                     freeSpace: FixedFreeSpace(.max))
    #expect(!again.summary.contains("Microphone echo found"))
}

@Test(.timeLimit(.minutes(2)))
func anAnalysisPutOffForDiskSpaceIsMadeByRecover() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let micOnly = SessionFixtures.transcript(call.echoSegments + call.ownSegments)
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: micOnly)
    let record = try await MeetingPostProcessor(diarizer: systemDiarizer(), options: .init(stopReason: .diskLow),
                                                freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    #expect(!record.stages.contains { $0.stage == .echo })
    #expect(EchoAnalysisStage.needed(session: session))
    let outcome = try await SessionRecoveryCommand.run(.init(session: session), diarizer: systemDiarizer(),
                                                       freeSpace: FixedFreeSpace(.max))
    #expect(outcome.summary.contains("Microphone echo found"))
    #expect(try shownMicSegments(session) == call.ownSegmentIDs)
}

// MARK: - echo-analyze

/// A call labelled before the analysis existed: others in the room, so the microphone is diarized; its echo and the
/// user's words are two clusters.
private func labelledOldCall(in root: URL) async throws -> (session: URL, call: CallTranscript, run: DiarizationRun) {
    let call = CallTranscript()
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
func echoAnalyzeChangesOnlyTheViewOfAnOldCall() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, call, run) = try await labelledOldCall(in: temp.url)
    let ownTurn = try #require(run.turns.first { $0.spans.first?.segmentID == call.ownSegments[1].id })
    let systemTurn = try #require(run.turns.first { $0.track == "system" })
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S2", name: "Person A")], session: session)
    try SessionFixtures.appendEdits([.reassignTurns(turnIDs: [systemTurn.id], to: "system:S2")], session: session)
    try SessionFixtures.appendEdits([.excludeFromEnrollment(turnIDs: [ownTurn.id])], session: session)
    let speakersBefore = speakerFiles(session)
    let transcriptBefore = try SessionFiles.currentTranscript(session: session)

    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(outcome.analysed)
    #expect(outcome.verdict == .echo)
    #expect(outcome.microphoneTurnsAfter == call.ownSegments.count)
    #expect(outcome.hiddenWords == call.echoSegments.reduce(0) { $0 + $1.words.count })
    #expect(!SessionFixtures.exists(SessionPaths.derived(session)))
    // Not one stored speaker file or transcript changed.
    #expect(speakerFiles(session) == speakersBefore)
    #expect(try SessionFiles.currentTranscript(session: session) == transcriptBefore)

    let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
    #expect(view.staleEdits.isEmpty)
    #expect(view.appliedEditIDs.count == 3)
    #expect(!view.speakers.contains { $0.id == "mic:S1" }, "The echo cluster has nothing left to show.")
    #expect(view.speakers.first { $0.id == "mic:S2" }?.name == "Person A")
    #expect(view.turns.first { $0.sourceTurnID == systemTurn.id }?.speakerID == "system:S2")
    #expect(view.turns.first { $0.sourceTurnID == ownTurn.id }?.excludedFromEnrollment == true)
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard1w2"))

    let again = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(!again.analysed)
    let forced = try await SessionEchoAnalyzeCommand.run(.init(session: session, force: true),
                                                         freeSpace: FixedFreeSpace(.max))
    #expect(forced.analysed)
    #expect(speakerFiles(session) == speakersBefore)
}

@Test(.timeLimit(.minutes(2)))
func anEditOnAPieceIsJournalledOnItsStoredTurn() async throws {
    // One microphone turn ("Me") runs from the user's words (8 s) through the far end's echo (10–16 s) to the user
    // again (16.8 s): the view shows it as two pieces, and an edit made on the second names the stored turn.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let mixed = SessionFixtures.segment((0..<24).map { "mixw\($0)" }, track: "mic", start: 8.0, wordSeconds: 0.4)
    let transcript = SessionFixtures.transcript(call.transcript.segments.filter { $0.track == "system" } + [mixed])
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: transcript)
    _ = try await MeetingPostProcessor(diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
    let pieces = view.turns.filter { $0.track == "mic" }
    #expect(pieces.count == 2)
    let stored = try #require(pieces.first?.sourceTurnID)
    #expect(pieces.allSatisfy { $0.sourceTurnID == stored && $0.cutByEcho })
    let second = pieces[1]
    #expect(second.id == "\(stored)~2")
    #expect(second.start > 16)

    try SessionFixtures.appendEdits([.reassignTurns(turnIDs: [second.id], to: "system:S1")], session: session)
    let journal = try SessionSpeakerStore.readEdits(session: session)
    #expect(journal.edits.last?.action == .reassignTurns(turnIDs: [stored], to: "system:S1"))
    let after = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
    #expect(after.turns.filter { $0.track == "mic" }.allSatisfy { $0.speakerID == "system:S1" })
}

@Test func echoAnalyzeLeavesAnInPersonMeetingAlone() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, run) = try await SessionFixtures.labelledSession(in: temp.url, track: "mic")
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == nil)
    #expect(!SessionFixtures.exists(EchoMaskStore.directory(session)))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == run.id)
}
