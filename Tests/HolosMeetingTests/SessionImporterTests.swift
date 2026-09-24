import AVFoundation
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// `holos session import` and `holos session score` (docs/meeting-design.md §5.5 PR7c), with generated audio and
// FakeSpeech; no speech assets or diarization models.

// MARK: - Helpers

/// Writes `seconds` of constant 16-bit PCM WAV audio: `values[c]` on channel c.
private func sessionImporterWriteWAV(_ url: URL, seconds: Double, sampleRate: Double = 44_100,
                                     values: [Float] = [0.5, 0.1]) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: values.count,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    let total = Int((seconds * sampleRate).rounded())
    let block = 8_192
    var written = 0
    while written < total {
        let frames = min(block, total - written)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for (channel, value) in values.enumerated() {
            for index in 0..<frames { data[channel][index] = value }
        }
        try file.write(from: buffer)
        written += frames
    }
}

/// A 10 s stereo 44.1 kHz WAV (left 0.5, right 0.1) in `folder`.
private func sessionImporterStereoWAV(in folder: URL, name: String = "meeting.wav") throws -> URL {
    let url = folder.appendingPathComponent(name)
    try sessionImporterWriteWAV(url, seconds: 10)
    return url
}

/// One recognized phrase, 1–2 s after the start of the speech session.
private func sessionImporterSegment() -> TranscriptSegment {
    TranscriptSegment(id: "S1", start: 1, end: 2, text: "hello there", words: [
        TimedWord(text: "hello", start: 1.0, end: 1.4, utf16Offset: 0, utf16Length: 5),
        TimedWord(text: "there", start: 1.5, end: 1.9, utf16Offset: 6, utf16Length: 5),
    ])
}

private func sessionImporterImport(_ file: URL, root: URL, speech: FakeSpeechFactory, vocabulary: [String] = [],
                                   transcribe: Bool = true,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
    try await SessionImporter.importAudio(from: file, name: "Imported", root: root, locale: "en-CA",
                                          backend: .speech, vocabulary: vocabulary, transcribe: transcribe,
                                          makeSpeech: speech.factory, progress: progress)
}

/// Polls `condition` every 5 ms for up to 10 s.
private func sessionImporterEventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Import

@Test(.timeLimit(.minutes(1)))
func importCreatesCompleteSession() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [sessionImporterSegment()])])
    let fractions = SharedValue<[Double]>([])
    let session = try await sessionImporterImport(wav, root: root, speech: speech) { fraction in
        fractions.update { $0.append(fraction) }
    }

    #expect(sessionFolders(in: root).map(\.lastPathComponent) == [session.lastPathComponent])
    let manifest = try SessionArchive.readManifest(at: session)
    #expect(manifest.status == ArchiveStatus.complete)
    #expect(manifest.name == "Imported")
    #expect(manifest.source == .microphone)
    #expect(!manifest.chunks.isEmpty)
    #expect(manifest.chunks.allSatisfy { $0.track == "mic" && $0.sampleRate == 44_100 && $0.channels == 1 })
    #expect(manifest.chunks.reduce(0) { $0 + $1.frameCount } == 441_000)
    #expect(abs((manifest.chunks.map(\.end).max() ?? 0) - 10) < 1e-6)
    // Channels are averaged: (0.5 + 0.1) / 2, within an Int16 step.
    let chunk = try AVAudioFile(forReading: session.appendingPathComponent(manifest.chunks[0].relativePath))
    #expect(chunk.fileFormat.commonFormat == .pcmFormatInt16)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: chunk.processingFormat, frameCapacity: 1_000))
    try chunk.read(into: buffer, frameCount: 1_000)
    let samples = try #require(buffer.floatChannelData)
    #expect(abs(samples[0][0] - 0.3) < 1e-3)
    #expect(abs(samples[0][999] - 0.3) < 1e-3)

    let info = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(session))
    #expect(info.sessionID == manifest.id)
    #expect(info.origin == .imported)
    #expect(info.mode == .inPerson)
    #expect(info.othersInRoom == false)
    #expect(info.importedFileName == "meeting.wav")
    #expect(!SessionFixtures.exists(SessionPaths.vocabulary(session)))

    let transcriptID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let transcript = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(transcriptID, in: session))
    #expect(transcript.locale == "en-CA")
    #expect(transcript.backend == .speech)
    #expect(transcript.segments.map(\.text) == ["hello there"])
    #expect(transcript.segments.first?.track == "mic")
    #expect(transcript.segments.first?.start == 1)
    // No speaker-less legacy exports: post-processing writes the exports.
    #expect(!SessionFixtures.exists(SessionPaths.export("txt", in: session)))
    #expect(try !SessionArchive.isActive(at: session))
    #expect(try !SessionArchive.isProcessing(at: session))

    #expect(speech.calls == [FakeSpeechFactory.Call(locale: "en-CA", backend: .speech, contextualStrings: [])])
    let fed = try #require(speech.sessions.first)
    #expect(abs(await fed.fedSeconds - 10) < 1e-6)
    let reported = fractions.value
    #expect(reported.last == 1)
    #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 < $1 })
    #expect(reported.contains { $0 > 0 && $0 < 1 })
}

@Test(.timeLimit(.minutes(1)))
func importPassesVocabulary() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [sessionImporterSegment()])])
    let session = try await sessionImporterImport(wav, root: temp.url.appendingPathComponent("Sessions"),
                                                  speech: speech, vocabulary: ["Maria Chen"])

    #expect(speech.calls.map(\.contextualStrings) == [["Maria Chen"]])
    let vocabulary = try AtomicFile.readJSON(MeetingVocabulary.self, from: SessionPaths.vocabulary(session))
    #expect(vocabulary == MeetingVocabulary(strings: ["Maria Chen"]))
    #expect(SessionFixtures.mode(SessionPaths.vocabulary(session)) == 0o600)
}

@Test func importCleansVocabularyAsARecordingDoes() {
    let long = String(repeating: "x", count: 101)
    #expect(SessionImporter.cleaned(["  Maria Chen ", "", "   ", long, "Strata"]) == ["Maria Chen", "Strata"])
    #expect(SessionImporter.cleaned((0..<1_200).map { "term \($0)" }).count == 1_000)
}

@Test(.timeLimit(.minutes(1)))
func importWithoutTranscriptionIsAudioOnly() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let speech = FakeSpeechFactory()
    let fractions = SharedValue<[Double]>([])
    let session = try await sessionImporterImport(wav, root: temp.url.appendingPathComponent("Sessions"),
                                                  speech: speech, transcribe: false) { fraction in
        fractions.update { $0.append(fraction) }
    }

    let manifest = try SessionArchive.readManifest(at: session)
    #expect(manifest.status == ArchiveStatus.audioOnly)
    #expect(manifest.chunks.reduce(0) { $0 + $1.frameCount } == 441_000)
    #expect(try SessionArchive.currentTranscriptID(at: session) == nil)
    #expect(speech.calls.isEmpty)
    #expect(try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(session)).origin == .imported)
    #expect(fractions.value.last == 1)
}

@Test(.timeLimit(.minutes(1)))
func importOfAFileThatIsNotAudioCreatesNothing() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let fake = temp.url.appendingPathComponent("notes.wav")
    try Data("not audio".utf8).write(to: fake)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let speech = FakeSpeechFactory()

    await #expect(throws: HolosError.self) {
        _ = try await sessionImporterImport(fake, root: root, speech: speech)
    }
    await #expect(throws: HolosError.self) {
        _ = try await sessionImporterImport(temp.url.appendingPathComponent("missing.wav"), root: root, speech: speech)
    }
    #expect(sessionFolders(in: root).isEmpty)
    #expect(speech.calls.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func importWhoseTranscriptionFailsLeavesNoSession() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let speech = FakeSpeechFactory([FakeSpeechScript(makeError: .unavailable("Speech assets are missing."))])

    do {
        _ = try await sessionImporterImport(wav, root: root, speech: speech)
        Issue.record("The import should have failed.")
    } catch let error as HolosError {
        guard case .unavailable(let message) = error else {
            Issue.record("Unexpected error kind: \(error)")
            return
        }
        #expect(message.contains("could not be transcribed"))
        #expect(message.contains("Speech assets are missing."))
    }
    #expect(sessionFolders(in: root).isEmpty)
    #expect(FileManager.default.fileExists(atPath: wav.path))
}

@Test(.timeLimit(.minutes(1)))
func cancelledImportLeavesNoSession() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    // The speech session never finishes on its own, so the import is still running when it is cancelled.
    let speech = FakeSpeechFactory([FakeSpeechScript(finishHangs: true)])
    let task = Task { try await sessionImporterImport(wav, root: root, speech: speech) }
    let finishing = await sessionImporterEventually {
        guard let session = speech.sessions.first else { return false }
        return await session.finishCalls > 0
    }
    #expect(finishing)
    #expect(sessionFolders(in: root).count == 1)
    task.cancel()

    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(sessionFolders(in: root).isEmpty)
    #expect(await speech.sessions.first?.cancelled == true)
}

// MARK: - Score

/// Otter's layout for the fixture's four 5 s turns (S1, S2, S1, S2): two named people, then the footer.
private let sessionScorerOtterText = """
    Maria Chen  0:00
    Good morning everyone, let's start with the budget.

    Jim Park  0:05
    Thanks Maria. The numbers are in the shared folder.

    Maria Chen  0:10
    Great, next item then.

    Jim Park  0:15
    Agreed.

    Transcribed by https://otter.ai
    """

/// A finished in-person session with the fixture's two alternating speakers labelled by FakeDiarizer.
private func sessionScorerSession(in root: URL) async throws -> URL {
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: root, mode: .inPerson, transcript: transcript)
    try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                     outputs: ["mic": SessionFixtures.alternatingOutput()])
    return session
}

@Test(.timeLimit(.minutes(1)))
func scoreJSONHasNoNames() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let session = try await sessionScorerSession(in: temp.url)
    let report = try SessionScorer.score(session: session, otterTranscript: sessionScorerOtterText)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let json = String(decoding: try encoder.encode(report), as: UTF8.self)
    let text = report.summaryLines.joined(separator: "\n")
    for output in [json, text, String(describing: report), String(reflecting: report)] {
        for word in ["Maria", "Chen", "Jim", "Park", "morning", "budget", "Agreed", "otter.ai"] {
            #expect(!output.contains(word), "a label or transcript word reached the output")
        }
    }
    let maria = SessionScorer.labelKey("Maria Chen")
    let jim = SessionScorer.labelKey("Jim Park")
    for key in [maria, jim] {
        #expect(key.count == 12)
        #expect(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
    #expect(report.mapping == [maria: "mic:S1", jim: "mic:S2"])
    #expect(json.contains("\"\(maria)\" : \"mic:S1\""))
    #expect(report.mappingSize == 2)
    #expect(report.referenceSpeakers == 2)
    #expect(report.referenceSpeakersOver30s == 0)
    #expect(report.holosSpeakers == 2)
    #expect(report.agreementConfusion == 0)
    #expect(report.comparedSeconds > 15)
    #expect(report.turnAgreementConfusion == 0)
    #expect(report.turnComparedSeconds > 0)
    #expect(report.genericLabels.isEmpty)
    #expect(report.audioSeconds == 20)
    #expect(report.runID == (try SessionSpeakerStore.readHead(session: session))?.runID)
    #expect(report.engineConfiguration == DiarizationEngineInfo.fake.configuration)
    #expect(text.contains("Reference speakers: 2"))
    #expect(text.contains("Mapped speakers: 2"))
}

@Test(.timeLimit(.minutes(1)))
func scoreCountsConfusionAndMarksGenericLabels() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let session = try await sessionScorerSession(in: temp.url)
    // Otter hears one speaker for the first 10 s and gives the second half to an unnamed speaker.
    let otter = "Maria Chen  0:00\nHello.\n\nSpeaker 2  0:10\nHi.\n"
    let report = try SessionScorer.score(session: session, otterTranscript: otter, collar: 0)

    let generic = SessionScorer.labelKey("Speaker 2")
    #expect(report.genericLabels == [generic])
    #expect(report.referenceSpeakers == 2)
    // Each Otter label shares 5 s with each Holos speaker, so whichever one-to-one mapping wins, half disagrees.
    #expect(report.mapping.count == 2)
    #expect(abs(report.agreementConfusion - 0.5) < 1e-9)
    #expect(abs(report.comparedSeconds - 20) < 1e-9)
}

@Test func genericOtterLabelsAreRecognized() {
    for label in ["Speaker 1", "speaker 12", "Speaker", "Unknown Speaker", "Unknown", "Unidentified Speaker 2"] {
        #expect(SessionScorer.isGenericLabel(label), "a generic label was taken for a name")
    }
    for label in ["Maria Chen", "Speakerphone Room", "Jim", "Unknown Pleasures Band"] {
        #expect(!SessionScorer.isGenericLabel(label), "a name was taken for a generic label")
    }
}

@Test(.timeLimit(.minutes(1)))
func scoreNeedsSpeakerLabelsAndTurns() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let unlabelled = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    #expect(throws: HolosError.self) {
        _ = try SessionScorer.score(session: unlabelled, otterTranscript: sessionScorerOtterText)
    }
    let labelled = try await sessionScorerSession(in: temp.url)
    #expect(throws: HolosError.self) {
        _ = try SessionScorer.score(session: labelled, otterTranscript: "No headers here.\n")
    }
    #expect(throws: HolosError.self) {
        _ = try SessionScorer.score(session: labelled, otterTranscript: sessionScorerOtterText, collar: -1)
    }
}
