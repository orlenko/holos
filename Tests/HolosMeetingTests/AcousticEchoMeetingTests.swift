import Accelerate
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Synchronization
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

/// A finished call whose tracks hold `audio` (16 kHz), with `transcript` saved as current (none: not transcribed).
private func callSession(in root: URL, audio: [String: [Float]], transcript: Transcript?, othersInRoom: Bool = false,
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
    if let transcript { try await archive.saveTranscript(transcript, writeLegacyExports: false) }
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
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
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
    let again = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), options: .init(force: true),
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
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    let manifest = try SessionArchive.readManifest(at: session)
    let stored = try #require(try EchoMaskStore.current(session: session, manifest: manifest))
    #expect(stored.record.verdict == .noEcho)
    #expect(stored.mask == nil)
    #expect(EchoMaskStore.framesFiles(session).isEmpty)
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
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: FakeDiarizer(outputs: [:]), freeSpace: FixedFreeSpace(.max))
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
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
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
    let first = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(first.stages.first { $0.stage == .echo }?.result == .failed)
    #expect(first.stages.first { $0.stage == .align }?.result == .succeeded)
    #expect(!SessionFixtures.exists(EchoMaskStore.recordURL(session)))
    #expect(EchoAnalysisStage.needed(session: session))
    #expect(try SessionRecoveryCommand.currentLabels(session, transcriptID: call.transcript.id, canLabel: true) != nil,
            "The labels themselves are current; the analysis is owed by the files, not by this record.")
    try moveMicrophoneAudio(session, away: false)
    let second = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), options: .init(force: true),
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
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
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
    let processed = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(!processed.stages.contains { $0.stage == .echo })
    #expect(try Data(contentsOf: EchoMaskStore.recordURL(session)) == newerBytes)
    #expect(try shownMicSegments(session) == call.echoSegmentIDs.union(call.ownSegmentIDs))
    // A frames file that is not the one the record names: damaged, so not used.
    try EchoMaskStore.write(record(audio: key), mask: mask, session: session)
    let named = try #require(record(audio: key).frames?.sha256)
    try AtomicFile.write(Data([1, 1, 1, 0, 0, 0]), to: try #require(EchoMaskStore.framesURL(session, sha256: named)))
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
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    try moveMicrophoneAudio(session, away: false)
    #expect(EchoAnalysisStage.needed(session: session))

    let short = try await SessionRecoveryCommand.run(.init(session: session), voiceSamples: .none, diarizer: systemDiarizer(),
                                                     freeSpace: FixedFreeSpace(0))
    #expect(short.warnings.filter { $0.contains("echo was not analysed") }.count == 1)
    #expect(short.exitCode == 3)
    #expect(EchoAnalysisStage.needed(session: session))

    let outcome = try await SessionRecoveryCommand.run(.init(session: session), voiceSamples: .none, diarizer: systemDiarizer(),
                                                       freeSpace: FixedFreeSpace(.max))
    #expect(outcome.postProcessing == nil, "The labels were current; only the analysis was owed.")
    #expect(outcome.summary.contains("Microphone echo found"))
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard0w0"))
    let again = try await SessionRecoveryCommand.run(.init(session: session), voiceSamples: .none, diarizer: systemDiarizer(),
                                                     freeSpace: FixedFreeSpace(.max))
    #expect(!again.summary.contains("Microphone echo found"))
}

@Test(.timeLimit(.minutes(2)))
func transcriptFilesWrittenWithAnotherMaskAreOutOfDateAndRecoverRewritesThem() async throws {
    // The meeting is labelled while its microphone audio cannot be read (files written without a mask); a mask is
    // then saved by a pass that did not get to rewrite the files.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    try moveMicrophoneAudio(session, away: true)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    try moveMicrophoneAudio(session, away: false)
    let title = { SessionCatalog.summary(session: session, jobState: .free).displayTitle }
    #expect(SessionExports.filesState(session: session, title: title()) == .current)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard0w0"))

    let manifest = try SessionArchive.readManifest(at: session)
    _ = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest, freeSpace: FixedFreeSpace(.max))
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(SessionExports.filesState(session: session, title: title()) == .stale, "The app offers the update.")
    #expect(!SessionExports.echoMaskIsCurrent(session: session))

    // Recover has no analysis to make, and rewrites the files from what the files say.
    let outcome = try await SessionRecoveryCommand.run(.init(session: session), voiceSamples: .none, diarizer: systemDiarizer(),
                                                       freeSpace: FixedFreeSpace(.max))
    #expect(outcome.warnings.isEmpty)
    #expect(SessionExports.filesState(session: session, title: title()) == .current)
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard0w0"))

    // Dropping the mask makes them out of date again.
    try FileManager.default.removeItem(at: EchoMaskStore.directory(session))
    #expect(SessionExports.filesState(session: session, title: title()) == .stale)
}

@Test(.timeLimit(.minutes(2)))
func aMaskIsSavedOnlyUnderTheSpeakerLock() async throws {
    // While someone holds the speaker lock (a voice sample checking the labels and the echo files before publishing
    // it), no mask can land.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    try SessionArchive.withSpeakerLock(at: session) {
        #expect(throws: HolosError.self) {
            _ = try EchoAnalysisStage.analyze(session: session, manifest: manifest, microphone: nil, system: nil)
        }
    }
    #expect(!SessionFixtures.exists(EchoMaskStore.recordURL(session)))
    _ = try EchoAnalysisStage.analyze(session: session, manifest: manifest, microphone: nil, system: nil)
    #expect(SessionFixtures.exists(EchoMaskStore.recordURL(session)))
}

/// Gives every turn the same embedding.
private struct FixedVoice: VoiceSampleExtractor {
    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        turns.map { TurnEmbedding(turnID: $0.id, speechSeconds: $0.end - $0.start, vector: FloatVector([1, 0, 0])) }
    }
}


/// An older call whose microphone turn ("Me", 8–17.6 s) runs through the far end's echo (10–16 s), labelled before
/// the echo was found (its microphone audio could not be read then), whose voice the user then linked and learned:
/// the people store holds one sample from it. With `ownTurn`, "Me" also has a turn of the user alone (26.6–29.4 s,
/// while the call is quiet), so a sample can be recomputed without the echo.
private func learnedBeforeTheEcho(in temp: TemporaryDirectory,
                                  ownTurn: Bool = false) async throws -> (URL, SpeakerProfileStore) {
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
    try store.update { $0.rememberVoices = true }
    let call = CallTranscript()
    let mixed = SessionFixtures.segment((0..<24).map { "mixw\($0)" }, track: "mic", start: 8.0, wordSeconds: 0.4)
    let own = SessionFixtures.segment((0..<7).map { "alonew\($0)" }, track: "mic", start: 26.6, wordSeconds: 0.4)
    let transcript = SessionFixtures.transcript(call.transcript.segments.filter { $0.track == "system" } + [mixed]
                                                + (ownTurn ? [own] : []))
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: transcript)
    try moveMicrophoneAudio(session, away: true)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    try moveMicrophoneAudio(session, away: false)
    let view = try SessionFixtures.view(session)
    let me = try #require(view.turns.first { $0.track == "mic" }?.speakerID)
    _ = try await VoiceProfileService.link(session: session, speakerID: me, to: .new(name: "Person A"), view: view,
                                           learnVoice: true, extractor: FixedVoice(), store: store)
    #expect(try store.load().profiles.flatMap(\.samples).count == 1)
    return (session, store)
}

/// Once the echo is found, the turn's voice data covers echo, so the sample learned from it is not kept; the person
/// stays.
private func expectSampleDropped(_ store: SpeakerProfileStore) throws {
    #expect(try store.load().profiles.flatMap(\.samples).isEmpty)
    #expect(try store.load().profiles.map(\.displayName) == ["Person A"])
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeBringsTheMeetingsVoiceSamplesInStep() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp)
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: fixedVoice,
                                                          profiles: store,
                                                          freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == .echo)
    try expectSampleDropped(store)
}

@Test(.timeLimit(.minutes(2)))
func postProcessingThatSavesAMaskForEditedLabelsBringsTheSamplesInStep() async throws {
    // `session diarize --keep-transcript` without --force: the edited labels are kept, the mask is saved, and the
    // sample is brought in step before anything else.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp)
    let headBefore = try SessionSpeakerStore.readHead(session: session)?.runID
    let outcome = try await SessionDiarizeCommand.run(
        .init(session: session, options: PostProcessingOptions(keepTranscript: true)), voiceSamples: fixedVoice,
        diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max), profiles: store)
    #expect(outcome.record.stages.contains { $0.stage == .echo && $0.result == .succeeded })
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == headBefore, "The edited labels were kept.")
    try expectSampleDropped(store)
}

@Test(.timeLimit(.minutes(2)))
func aMaskSavedWithoutUpdatingSamplesIsCaughtUpByTheNextPass() async throws {
    // A pass saved the mask but did not bring the samples in step (no voice extractor). Freshness comes from the
    // files: a plain echo-analyze, which has no analysis to make, still catches the sample up, and so does Recover.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp)
    _ = try await SessionDiarizeCommand.run(
        .init(session: session, options: PostProcessingOptions(keepTranscript: true)), voiceSamples: .none,
        diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max), profiles: store)
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(try store.load().profiles.flatMap(\.samples).count == 1)
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: fixedVoice,
                                                          profiles: store,
                                                          freeSpace: FixedFreeSpace(.max))
    #expect(!outcome.analysed)
    try expectSampleDropped(store)

    let second = try TemporaryDirectory("echo")
    defer { second.remove() }
    let (other, otherStore) = try await learnedBeforeTheEcho(in: second)
    _ = try await SessionDiarizeCommand.run(
        .init(session: other, options: PostProcessingOptions(keepTranscript: true)), voiceSamples: .none,
        diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max), profiles: otherStore)
    let recovered = try await SessionRecoveryCommand.run(.init(session: other), voiceSamples: fixedVoice,
                                                         diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max),
                                                         profiles: otherStore)
    #expect(recovered.warnings.isEmpty)
    try expectSampleDropped(otherStore)
}

@Test(.timeLimit(.minutes(2)))
func aPassThatKeepsTheLabelsStillChecksTheEchoAndTheSamples() async throws {
    // `session fix-words` with nothing to fix keeps the labels as they are (no labelling stages). It is still a pass
    // that ends with labels: the missing analysis is made and the sample brought in step.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp)
    #expect(EchoAnalysisStage.needed(session: session))
    let outcome = try await SessionWordFixesCommand.run(.init(session: session), voiceSamples: fixedVoice,
                                                        diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max),
                                                        profiles: store, wordFixes: .none)
    #expect(outcome.record.stages.contains { $0.stage == .align && $0.result == .skipped })
    #expect(outcome.record.stages.contains { $0.stage == .echo && $0.result == .succeeded })
    #expect(!EchoAnalysisStage.needed(session: session))
    try expectSampleDropped(store)
}

@Test(.timeLimit(.minutes(2)))
func anEditOnAViewShownWithAnotherMaskIsRefused() async throws {
    // The review loaded its view before echo-analyze saved a mask: the turns it shows are not the ones shown now.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, run) = try await labelledOldCall(in: temp.url)
    let stale = try SessionFixtures.view(session)
    #expect(stale.acousticEcho == nil)
    _ = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none,
                                                freeSpace: FixedFreeSpace(.max))
    let systemTurn = try #require(run.turns.first { $0.track == "system" }).id
    let edits = try SessionSpeakerStore.readEdits(session: session).edits
    let refusal = #expect(throws: HolosError.self) {
        _ = try SpeakerEditor.apply([.reassignTurns(turnIDs: [systemTurn], to: "system:S2")], view: stale,
                                    session: session, source: "test")
    }
    #expect(refusal?.localizedDescription.contains(SpeakerEditor.changedMessage) == true)
    #expect(try SessionSpeakerStore.readEdits(session: session).edits == edits, "Nothing was written.")
    // A view loaded now is accepted.
    let current = try SessionFixtures.view(session)
    #expect(current.acousticEcho != nil)
    _ = try SpeakerEditor.apply([.reassignTurns(turnIDs: [systemTurn], to: "system:S2")], view: current,
                                session: session, source: "test")
    #expect(try SessionSpeakerStore.readEdits(session: session).edits.count == edits.count + 1)
}

@Test(.timeLimit(.minutes(2)))
func aCallWithNoTranscriptGetsItsAnalysisAndNoFailure() async throws {
    // Recorded (or imported) without a transcript: echo-analyze saves the analysis and says there are no labels yet;
    // Recover, with people who have voice samples from other meetings, does not fail on the sample check.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: nil)
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
    try store.update {
        $0.rememberVoices = true
        $0.profiles = [SpeakerProfile(id: "P1", displayName: "Person A", embeddingModel:
                                        DiarizationEngineInfo.fake.embeddingModel, samples: [
            VoiceprintSample(sessionID: UUID().uuidString, sessionName: "Other meeting", speakerIDs: ["mic:S1"],
                             speechSeconds: 60, embedding: FloatVector([1, 0, 0]), condition: .room, weak: false),
        ])]
    }
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: fixedVoice,
                                                          profiles: store, freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == .echo)
    #expect(outcome.summary.contains("no speaker labels yet"))
    #expect(outcome.microphoneTurnsAfter == nil)
    #expect(!EchoAnalysisStage.needed(session: session))

    let recovered = try await SessionRecoveryCommand.run(.init(session: session, transcribe: false),
                                                         voiceSamples: fixedVoice, diarizer: systemDiarizer(),
                                                         freeSpace: FixedFreeSpace(.max), profiles: store)
    #expect(!recovered.warnings.contains { $0.contains("voice sample") })
    #expect(try store.load().profiles.flatMap(\.samples).count == 1)
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeRewritesSpeakerlessTranscriptFiles() async throws {
    // A transcript and its files, but no speaker labels (post-processed without speaker models): the files are
    // rewritten with the mask recorded, so they are not left out of date.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true),
                                        transcript: CallTranscript().transcript)
    try SessionExports.regenerate(session: session)
    #expect(try SessionSpeakerStore.readHead(session: session) == nil)
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none,
                                                          freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == .echo)
    #expect(outcome.summary.contains("no speaker labels yet"))
    #expect(outcome.exitCode == 0)
    #expect(SessionExports.echoMaskIsCurrent(session: session))
    let title = SessionCatalog.summary(session: session, jobState: .free).displayTitle
    #expect(SessionExports.filesState(session: session, title: title) == .current)
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeExitsThreeWhenTheTranscriptFilesCannotBeRewritten() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, _) = try await labelledOldCall(in: temp.url)
    // exports/ cannot be written: a file stands where the folder goes.
    try FileManager.default.removeItem(at: SessionPaths.exports(session))
    try Data("not a folder".utf8).write(to: SessionPaths.exports(session))
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none,
                                                          freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == .echo)
    #expect(outcome.summary.contains("could not be rewritten"))
    #expect(outcome.exitCode == 3)
}

@Test(.timeLimit(.minutes(2)))
func aMissingOrDamagedFramesFileMakesTheCachedStatesOutOfDate() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, _) = try await labelledOldCall(in: temp.url)
    _ = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none,
                                                freeSpace: FixedFreeSpace(.max))
    let cache = TranscriptFilesCache()
    let summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(cache.state(of: summary) == .current)
    let stamp = MeetingPeopleCache.echoStamp(session)
    // The record is untouched; the frames it names are damaged, so the mask is dropped.
    let frames = try #require(EchoMaskStore.framesFiles(session).first)
    try Data([0, 1]).write(to: frames)
    #expect(EchoMaskStore.usable(session: session, manifest: try SessionArchive.readManifest(at: session)) == nil)
    #expect(MeetingPeopleCache.echoStamp(session) != stamp)
    #expect(cache.state(of: summary) == .stale)
    // And when it is removed.
    try FileManager.default.removeItem(at: frames)
    #expect(!MeetingPeopleCache.echoStamp(session).contains(frames.lastPathComponent))
    #expect(cache.state(of: summary) == .stale)
}

@Test(.timeLimit(.minutes(2)))
func anOldFramesFileThatCannotBeDeletedDoesNotFailTheSave() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true),
                                        transcript: CallTranscript().transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let old = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest,
                                                   freeSpace: FixedFreeSpace(.max))
    let oldMask = try #require(old.mask)
    var bytes = oldMask.bytes
    bytes[0] = bytes[0] == AcousticEchoMask.FrameClass.echo.rawValue
        ? AcousticEchoMask.FrameClass.local.rawValue : AcousticEchoMask.FrameClass.echo.rawValue
    let newMask = try #require(AcousticEchoMask(bytes: bytes, frameCount: oldMask.frameCount))
    var record = old.record
    record.frames?.sha256 = SessionExports.sha256(newMask.bytes)
    struct Busy: Error {}
    try EchoMaskStore.$removeFrames.withValue({ _ in throw Busy() }) {
        try EchoMaskStore.write(record, mask: newMask, session: session)
    }
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == newMask)
    #expect(EchoMaskStore.framesFiles(session).count == 2, "The old file is left for the next save.")
    try EchoMaskStore.write(record, mask: newMask, session: session)
    #expect(EchoMaskStore.framesFiles(session).count == 1)
}

@Test(.timeLimit(.minutes(2)))
func aNewMaskThatFailsBeforeItsRecordIsSwitchedLeavesTheOldOneInUse() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true),
                                        transcript: CallTranscript().transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let old = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest,
                                                   freeSpace: FixedFreeSpace(.max))
    let oldMask = try #require(old.mask)
    // Another mask (the first frame's class changed), with its record.
    var bytes = oldMask.bytes
    bytes[0] = bytes[0] == AcousticEchoMask.FrameClass.echo.rawValue
        ? AcousticEchoMask.FrameClass.local.rawValue : AcousticEchoMask.FrameClass.echo.rawValue
    let newMask = try #require(AcousticEchoMask(bytes: bytes, frameCount: oldMask.frameCount))
    var record = old.record
    record.frames?.sha256 = SessionExports.sha256(newMask.bytes)
    struct Crash: Error {}
    #expect(throws: Crash.self) {
        try EchoMaskStore.$afterFramesWritten.withValue({ throw Crash() }) {
            try EchoMaskStore.write(record, mask: newMask, session: session)
        }
    }
    // The record still names the old frames, which are still there: the old mask loads.
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == oldMask)
    #expect(EchoMaskStore.framesFiles(session).count == 2)
    // The next write switches to its own frames and removes every other file.
    try EchoMaskStore.write(record, mask: newMask, session: session)
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) == newMask)
    #expect(EchoMaskStore.framesFiles(session).map(\.lastPathComponent)
        == ["frames-\(record.frames!.sha256.prefix(16)).bin"])
}

/// `FixedVoice` for every session.
private let fixedVoice = VoiceSampleSource.make { _ in FixedVoice() }

/// Fails every extraction.
private struct BrokenVoice: VoiceSampleExtractor {
    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        throw HolosError.io("The voice could not be read.")
    }
}

@Test(.timeLimit(.minutes(2)))
func aSampleSyncThatFailsAfterTheMaskIsSavedIsRetriedByTheNextPass() async throws {
    // The pass that saves the mask cannot recompute the sample (its extraction fails); nothing records that, so the
    // next post-processing pass, which has no analysis left to make, brings the sample in step.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp, ownTurn: true)
    let learned = try #require(try store.load().profiles.first?.samples.first)
    let keep = PostProcessingOptions(keepTranscript: true)
    let first = try await SessionDiarizeCommand.run(.init(session: session, options: keep),
                                                    voiceSamples: .make { _ in BrokenVoice() },
                                                    diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max),
                                                    profiles: store)
    let echo = try #require(first.record.stages.first { $0.stage == .echo })
    #expect(echo.result == .succeeded)
    #expect(echo.message?.contains("could not be updated") == true)
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(try store.load().profiles.first?.samples == [learned], "Left as it was.")

    let second = try await SessionDiarizeCommand.run(.init(session: session, options: keep), voiceSamples: fixedVoice,
                                                     diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max),
                                                     profiles: store)
    #expect(!second.record.stages.contains { $0.stage == .echo }, "No analysis left to make.")
    let refreshed = try #require(try store.load().profiles.first?.samples.first)
    #expect(refreshed.id == learned.id)
    #expect(refreshed.inputDigest != learned.inputDigest, "Recomputed from the user's own turn alone.")
}

/// Says it was asked for a voice, then waits until its task is cancelled (a long call's voice sample recomputed).
private final class StalledVoice: VoiceSampleExtractor {
    private let asked = Mutex(false)

    var wasAsked: Bool { asked.withLock { $0 } }

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        asked.withLock { $0 = true }
        try await Task.sleep(for: .seconds(3_600))
        return []
    }
}

@Test(.timeLimit(.minutes(2)))
func echoAnalyzeStoppedForAMeetingLeavesWhatItDidNotFinishForTheNextRun() async throws {
    // The app stops its run (SIGTERM, which cancels the command's task) when a meeting starts. On a long call the
    // voice samples are the long part: stopped there, the mask and the transcript files are saved, the sample is as
    // it was, the job lock is let go of, and the catch-up still finds the meeting, so the next run finishes it.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp, ownTurn: true)
    let learned = try #require(try store.load().profiles.first?.samples.first)
    let id = try SessionArchive.readManifest(at: session).id
    let lock = temp.url.appendingPathComponent("deep-transcription.lock")

    // Stopped before it starts: nothing is done.
    let early = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SessionEchoAnalyzeCommand.run(.init(session: session, jobLock: lock),
                                                       voiceSamples: fixedVoice, profiles: store,
                                                       freeSpace: FixedFreeSpace(.max))
    }
    await #expect(throws: CancellationError.self) { try await early.value }
    #expect(EchoAnalysisStage.needed(session: session))

    let voice = StalledVoice()
    let run = Task {
        try await SessionEchoAnalyzeCommand.run(.init(session: session, jobLock: lock),
                                                voiceSamples: .make { _ in voice }, profiles: store,
                                                freeSpace: FixedFreeSpace(.max))
    }
    #expect(await eventually { voice.wasAsked })
    #expect(DeepTranscriptionLock.state(at: lock) == .held(DeepTranscriptionLock.Holder(
        pid: getpid(), sessionID: id, force: false, kind: DeepTranscriptionLock.Holder.echoKind)),
            "Held for the whole run, the voice samples included.")
    run.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(DeepTranscriptionLock.state(at: lock) == .free)
    #expect(!EchoAnalysisStage.needed(session: session), "The mask was saved before the samples.")
    #expect(SessionExports.echoMaskIsCurrent(session: session), "So were the transcript files.")
    #expect(try store.load().profiles.first?.samples == [learned], "Left as it was.")
    #expect(EchoCatchUpSchedule.needsAnalysis(session: session, profiles: store), "Still owed: found again.")

    let again = try await SessionEchoAnalyzeCommand.run(.init(session: session, jobLock: lock), voiceSamples: fixedVoice,
                                                        profiles: store, freeSpace: FixedFreeSpace(.max))
    #expect(!again.analysed)
    #expect(again.exitCode == 0)
    #expect(try store.load().profiles.first?.samples.first?.inputDigest != learned.inputDigest)
    #expect(!EchoCatchUpSchedule.needsAnalysis(session: session, profiles: store))
}

@Test(.timeLimit(.minutes(2)))
func aSampleFromAnEarlierRunWhoseTurnsAreNowEchoIsNotKept() async throws {
    // The sample was learned from run R1. A forced relabel (R2) runs with no voice sample source, and saves the
    // mask. In R2 the user's turn is cut by echo, so R2 gives no sample; the R1 sample, seen through the mask, has
    // lost its turn too, so the next sync removes it instead of keeping it as an earlier run's.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp)
    let firstRun = try SessionSpeakerStore.readHead(session: session)?.runID
    _ = try await SessionDiarizeCommand.run(
        .init(session: session, options: PostProcessingOptions(force: true, keepTranscript: true)), voiceSamples: .none,
        diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max), profiles: store)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID != firstRun)
    #expect(!EchoAnalysisStage.needed(session: session))
    #expect(try store.load().profiles.flatMap(\.samples).count == 1)

    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: fixedVoice,
                                                          profiles: store,
                                                          freeSpace: FixedFreeSpace(.max))
    #expect(!outcome.analysed)
    try expectSampleDropped(store)
}

/// The sample was learned from run R1 with no echo found yet; Remember voices was then turned off (saved samples are
/// kept). A word of the far end's (system track) is corrected in Review: the labels move to R2, the same labelling.
/// The echo catch-up then finds the far end's echo in "Me"'s mixed turn, while her own turn still qualifies. R1 can be
/// read, and only without the mask does it give the sample's inputs: the sample was learned from a turn now echo, so
/// it is out of step (the catch-up's refresh acts), and with Remember voices off it is removed, not kept.
@Test(.timeLimit(.minutes(2))) @MainActor
func aSampleFromBeforeAWordEditWhoseTurnIsNowEchoIsRemovedEvenWithLearningOff() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, store) = try await learnedBeforeTheEcho(in: temp, ownTurn: true)
    let learned = try #require(try store.load().profiles.first?.samples.first)
    try store.update { $0.rememberVoices = false }
    let review = try await ReviewSession(session: session, profiles: nil, maintenance: nil, exportDelay: .seconds(60))
    let farEnd = try #require(review.projection.turns.first { $0.track == "system" })
    let word = try #require(review.words(of: farEnd.id).first)
    try await review.editWords([word.ref], to: "corrected")
    await review.close()
    let head = try #require(try SpeakerSessionSnapshot.load(session: session).run)
    #expect(head.labelling != nil && VoiceProfileService.sourceRunID(learned) != head.id)
    #expect(!VoiceProfileService.samplesOutOfStep(session: session, store: store), "In step before the echo.")
    // The catch-up's analysis saves the mask (its sample refresh comes after).
    let manifest = try SessionArchive.readManifest(at: session)
    let stored = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest,
                                                      freeSpace: FixedFreeSpace(.max))
    #expect(stored.record.verdict == .echo)
    let view = try SessionFixtures.view(session)
    #expect(view.turns.contains { $0.track == "mic" && $0.cutByEcho }, "The mixed turn is echo now.")
    #expect(view.turns.contains { $0.track == "mic" && !$0.cutByEcho }, "Her own turn still qualifies.")
    #expect(VoiceProfileService.samplesOutOfStep(session: session, store: store), "The catch-up's refresh acts.")
    try await VoiceProfileService.refreshSamples(session: session, extractor: FixedVoice(), store: store)
    try expectSampleDropped(store)
    #expect(!VoiceProfileService.samplesOutOfStep(session: session, store: store))
}

@Test(.timeLimit(.minutes(2)))
func aCallLongerThanAMaskIsKeptForIsSavedAsTooLongAndCountsAsDone() async throws {
    // One limit, made tiny here (100 frames, 1.6 s): the analysis does not write a frames file the reader would refuse
    // (and analyse again every pass); it saves `tooLong`, which hides nothing and is not analysed again.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    try EchoMaskStore.$maximumFrames.withValue(100) {
        let stored = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest,
                                                          freeSpace: FixedFreeSpace(.max))
        #expect(stored.record.verdict == .tooLong)
        #expect(stored.mask == nil)
        #expect(EchoMaskStore.framesFiles(session).isEmpty)
        #expect(try EchoMaskStore.current(session: session, manifest: manifest)?.record.verdict == .tooLong)
        #expect(!EchoAnalysisStage.needed(session: session))
        #expect(EchoMaskStore.usable(session: session, manifest: manifest) == nil)
        #expect(EchoAnalysisStage.message(stored.record).contains("longer than"))
    }
    // With the usual limit the same call is analysed, and its mask is one the reader takes.
    let stored = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest,
                                                      freeSpace: FixedFreeSpace(.max))
    #expect(stored.record.verdict == .echo)
    #expect(EchoMaskStore.usable(session: session, manifest: manifest) != nil)
    // A frames file past the limit is never read.
    EchoMaskStore.$maximumFrames.withValue(100) {
        #expect(EchoMaskStore.usable(session: session, manifest: manifest) == nil)
    }
}

@Test(.timeLimit(.minutes(2)))
func renderTimesFarOutsideAMeetingThrowInsteadOfTrapping() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: temp.url.appendingPathComponent("mic.caf"))
    var sane = rendered
    sane.timeMap = [RenderSpan(renderStart: 0, sessionStart: 5, duration: 1)]
    #expect(try RenderedEchoAudio(sane).sampleCount == 6 * EchoAnalysis.sampleRate)
    let edge = Double(RenderedEchoAudio.representable) / Double(EchoAnalysis.sampleRate) * 1.01
    for start in [1e15, -1e15, .infinity, .nan, edge] {
        var damaged = rendered
        damaged.timeMap = [RenderSpan(renderStart: 0, sessionStart: start, duration: 1)]
        #expect(throws: HolosError.self, "session start \(start)") { _ = try RenderedEchoAudio(damaged) }
    }
    var longRender = rendered
    longRender.timeMap = [RenderSpan(renderStart: 0, sessionStart: 0, duration: 1e300)]
    #expect(throws: HolosError.self) { _ = try RenderedEchoAudio(longRender) }
}

@Test(.timeLimit(.minutes(2)))
func anInterruptedRewriteWithoutAMaskIsNotCurrentAndRecoverFinishesIt() async throws {
    // Headphones: no mask, so a pending record (which names no mask) matches "none" by its mask alone.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: false), transcript: call.transcript)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(SessionExports.echoMaskIsCurrent(session: session))
    let url = SessionPaths.generatedExports(session)
    var record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    record["pending"] = record["files"]
    try JSONSerialization.data(withJSONObject: record).write(to: url)
    #expect(!SessionExports.echoMaskIsCurrent(session: session))

    let outcome = try await SessionRecoveryCommand.run(.init(session: session), voiceSamples: .none, diarizer: systemDiarizer(),
                                                       freeSpace: FixedFreeSpace(.max))
    #expect(outcome.warnings.isEmpty)
    #expect(SessionExports.echoMaskIsCurrent(session: session))
    let title = SessionCatalog.summary(session: session, jobState: .free).displayTitle
    #expect(SessionExports.filesState(session: session, title: title) == .current)
}

@Test(.timeLimit(.minutes(2)))
func anAnalysisPutOffForDiskSpaceIsMadeByRecover() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let micOnly = SessionFixtures.transcript(call.echoSegments + call.ownSegments)
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: micOnly)
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), options: .init(stopReason: .diskLow),
                                                freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    #expect(!record.stages.contains { $0.stage == .echo })
    #expect(EchoAnalysisStage.needed(session: session))
    let outcome = try await SessionRecoveryCommand.run(.init(session: session), voiceSamples: .none, diarizer: systemDiarizer(),
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

    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none, freeSpace: FixedFreeSpace(.max))
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
    #expect(view.turns.first { $0.id == systemTurn.id }?.speakerID == "system:S2")
    #expect(view.turns.first { $0.id == ownTurn.id }?.excludedFromEnrollment == true)
    #expect(!SessionFixtures.text(SessionPaths.export("md", in: session)).contains("heard1w2"))

    let again = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none, freeSpace: FixedFreeSpace(.max))
    #expect(!again.analysed)
    let forced = try await SessionEchoAnalyzeCommand.run(.init(session: session, force: true), voiceSamples: .none,
                                                         freeSpace: FixedFreeSpace(.max))
    #expect(forced.analysed)
    #expect(speakerFiles(session) == speakersBefore)
}

@MainActor
@Test(.timeLimit(.minutes(2)))
func theReviewSplitsAssignsAndUndoesATurnWithHiddenEchoAsItsStoredTurn() async throws {
    // One microphone turn ("Me") runs from the user's words (8 s) through the far end's echo (10–16 s) to the user
    // again (16.8 s): the review shows it as one turn, same ID, without the echo words.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let mixed = SessionFixtures.segment((0..<24).map { "mixw\($0)" }, track: "mic", start: 8.0, wordSeconds: 0.4)
    let transcript = SessionFixtures.transcript(call.transcript.segments.filter { $0.track == "system" } + [mixed])
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: transcript)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    let run = try #require(try SpeakerSessionSnapshot.load(session: session).run)
    let stored = try #require(run.turns.first { $0.track == "mic" })
    let review = try await ReviewSession(session: session, profiles: nil, maintenance: nil, exportDelay: .seconds(60))
    let shown = review.projection.turns.filter { $0.track == "mic" }
    #expect(shown.map(\.id) == [stored.id])
    #expect(shown.first?.cutByEcho == true)
    let words = review.words(of: stored.id)
    // The words shown jump over the echo: before it, the user's words up to 10 s; after it, theirs from 16 s.
    let gap = try #require(words.indices.dropFirst().first { words[$0].ref.word != words[$0 - 1].ref.word + 1 })
    #expect(words[..<gap].allSatisfy { $0.start < 10 })
    #expect(words[gap...].allSatisfy { $0.start >= 16 })
    #expect(words[gap].ref.word > gap)

    // The first word after the echo, picked by its place among the words shown (as the split sheet and
    // `speakers split --at-word` pick it), names that word of the segment: the split is made there in the stored
    // turn.
    let picked = try SpeakerSelector.splitWord(turnID: stored.id, atWord: gap + 1, at: nil, in: review.projection,
                                               transcript: review.snapshot.transcript)
    #expect(picked == words[gap].ref)
    try await review.split(turnID: stored.id, at: picked)
    let journal = try SessionSpeakerStore.readEdits(session: session)
    guard case .splitTurn(let turnID, let at)? = journal.edits.last?.action else {
        Issue.record("No split was journalled")
        return
    }
    #expect(turnID == stored.id)
    #expect(at == picked)
    let parts = review.projection.turns.filter { $0.track == "mic" }
    #expect(parts.map { review.words(of: $0) } == [Array(words[..<gap]), Array(words[gap...])])
    #expect(parts.first?.id == stored.id)

    // Assigning the second part names it; undo takes back the assignment, then the split.
    let second = try #require(parts.last).id
    try await review.assign([second], to: .speaker("system:S1"))
    #expect(review.projection.turns.first { $0.id == second }?.speakerID == "system:S1")
    #expect(review.projection.turns.first { $0.id == stored.id }?.speakerID == stored.speakerID)
    try await review.undo()
    #expect(review.projection.turns.first { $0.id == second }?.speakerID == stored.speakerID)
    try await review.undo()
    #expect(review.projection.turns.filter { $0.track == "mic" }.map(\.id) == [stored.id])
    #expect(review.words(of: stored.id) == words)
    await review.close()
}

@Test(.timeLimit(.minutes(2)))
func recognitionDoesNotCompareAMicrophoneClusterThatIsEcho() async throws {
    // S1 on the microphone is the far end's echo: its voice must not take a person's match from the system speaker.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, run) = try await labelledOldCall(in: temp.url)
    _ = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none, freeSpace: FixedFreeSpace(.max))
    let manifest = try SessionArchive.readManifest(at: session)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let clusters = run.speakers.flatMap(\.clusterIDs)
    let echoCluster = try #require(run.speakers.first { $0.id == "mic:S1" }?.clusterIDs.first)
    let voices = SessionVoiceData(runID: run.id, sessionID: manifest.id,
                                  embeddingModel: DiarizationEngineInfo.fake.embeddingModel,
                                  centroids: Dictionary(uniqueKeysWithValues: clusters.map { ($0, FloatVector([1, 0])) }),
                                  turnEmbeddings: [])
    let mask = EchoMaskStore.usable(session: session, manifest: manifest)
    let kept = RecognizeStage.withoutEcho(voices, run: run, transcript: snapshot.transcript, mask: mask)
    #expect(Set(kept?.centroids.keys ?? [:].keys) == Set(clusters).subtracting([echoCluster]))
    #expect(RecognizeStage.withoutEcho(voices, run: run, transcript: snapshot.transcript, mask: nil) == voices)
}

@Test func echoAnalyzeLeavesAnInPersonMeetingAlone() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let (session, _, run) = try await SessionFixtures.labelledSession(in: temp.url, track: "mic")
    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none, freeSpace: FixedFreeSpace(.max))
    #expect(outcome.verdict == nil)
    #expect(!SessionFixtures.exists(EchoMaskStore.directory(session)))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == run.id)
}

// MARK: - Word rule version

@Test(.timeLimit(.minutes(2)))
func transcriptFilesWrittenUnderTheEarlierWordRuleAreOutOfDateAndEchoAnalyzeRewritesThem() async throws {
    // Files written before the word rule asked for evidence recorded the mask by the SHA-256 of its frames alone.
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url, audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(SessionExports.echoMaskIsCurrent(session: session))
    let manifest = try SessionArchive.readManifest(at: session)
    let sha256 = try #require(try EchoMaskStore.current(session: session, manifest: manifest)?.record.frames?.sha256)
    #expect(EchoMaskStore.identity(session: session, manifest: manifest)
        == "\(sha256)+words\(AcousticEchoMask.wordRuleVersion)")
    let url = SessionPaths.generatedExports(session)
    var record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    record["echoMask"] = sha256
    try JSONSerialization.data(withJSONObject: record).write(to: url)
    let title = { SessionCatalog.summary(session: session, jobState: .free).displayTitle }
    #expect(SessionExports.filesState(session: session, title: title()) == .stale, "The app offers the update.")
    #expect(!SessionExports.echoMaskIsCurrent(session: session))
    #expect(!EchoAnalysisStage.needed(session: session), "The saved analysis is kept.")
    #expect(EchoCatchUpSchedule.needsAnalysis(session: session), "The app's catch-up rewrites the files.")

    let outcome = try await SessionEchoAnalyzeCommand.run(.init(session: session), voiceSamples: .none,
                                                          freeSpace: FixedFreeSpace(.max))
    #expect(!outcome.analysed)
    #expect(outcome.exitCode == 0)
    #expect(SessionExports.echoMaskIsCurrent(session: session))
    #expect(SessionExports.filesState(session: session, title: title()) == .current)
    #expect(!EchoCatchUpSchedule.needsAnalysis(session: session))
}

// MARK: - Echo label stats

@Test(.timeLimit(.minutes(2)))
func echoLabelStatsCountACallAndLeaveOtherMeetingsOut() async throws {
    let temp = try TemporaryDirectory("echo")
    defer { temp.remove() }
    let call = CallTranscript()
    let session = try await callSession(in: temp.url.appendingPathComponent("call"),
                                        audio: CallAudio.tracks(echo: true), transcript: call.transcript)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    let headphones = try await callSession(in: temp.url.appendingPathComponent("headphones"),
                                           audio: CallAudio.tracks(echo: false), transcript: call.transcript)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: systemDiarizer(), freeSpace: FixedFreeSpace(.max))
        .run(session: headphones, lease: nil)
    let files = speakerFiles(session)
    let exports = SessionFixtures.text(SessionPaths.export("md", in: session))

    let report = SessionEchoLabelStats.report([session, headphones, temp.url.appendingPathComponent("none.holos")])
    #expect(report.sessions.map(\.status) == [.measured, .noMask, .unreadable])
    #expect(report.measured == 1)
    #expect(report.exitCode == 0)
    let stats = try #require(report.sessions.first?.stats)
    let micWords = call.transcript.segments.filter { $0.track == "mic" }
        .reduce(0) { $0 + WordTiming.effectiveWords(of: $1).count }
    #expect(stats.microphoneWords == micWords)
    #expect(stats.judgedWords == micWords)
    #expect(stats.localAfter <= stats.localBefore)
    #expect(stats.echoToLocal == 0)
    #expect(stats.localBefore - stats.localAfter == stats.localToEcho)
    #expect(stats.microphoneRowsAfter != nil)
    #expect(report.total == stats)
    // Counts only: no word of the transcript, and no folder path.
    let lines = report.lines.joined(separator: "\n")
    #expect(report.lines.count == 4)
    for word in ["heard0w", "own0w", "far0w", temp.url.path] { #expect(!lines.contains(word)) }
    #expect(lines.contains(try SessionArchive.readManifest(at: session).id))
    #expect(report.lines.last?.hasPrefix("total (1 of 3 measured): ") == true)
    // It only reads.
    #expect(speakerFiles(session) == files)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)) == exports)
    #expect(SessionEchoLabelStats.report([headphones]).exitCode == 1)
}
