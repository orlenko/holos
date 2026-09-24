import AVFoundation
import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
@testable import HolosStorage
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

/// Every name in `root`, hidden ones included, sorted.
private func sessionImporterEntries(_ root: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
}

/// The hidden staging folders (`.import-<UUID>`) in `root`.
private func sessionImporterStagingFolders(_ root: URL) -> [String] {
    sessionImporterEntries(root).filter { $0.hasPrefix(ImportStaging.prefix) }
}

/// A staging folder as a killed import leaves it: a session folder inside, the ownership marker (unless `marker` is
/// false), and (unless `lockFile` is false) an unlocked `.import.lock`, last changed `age` seconds ago (2 hours,
/// past `ImportStaging.unlockedGrace`, unless given). Named `name` when given.
private func sessionImporterAbandonedStaging(in root: URL, lockFile: Bool = true, marker: Bool = true,
                                             name: String? = nil, age: TimeInterval = 7_200) throws -> String {
    let name = name ?? ImportStaging.prefix + UUID().uuidString
    let folder = root.appendingPathComponent(name, isDirectory: true)
    let session = folder.appendingPathComponent("\(UUID().uuidString).holos/audio/mic", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 64).write(to: session.appendingPathComponent("000001.caf"))
    if marker {
        try Data(ImportStaging.markerContents).write(to: folder.appendingPathComponent(ImportStaging.markerName))
    }
    if lockFile { try Data().write(to: folder.appendingPathComponent(ImportStaging.lockName)) }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                          ofItemAtPath: folder.path)
    return name
}

/// Every file under `folder`, relative paths, sorted.
private func sessionImporterTree(_ folder: URL) -> [String] {
    let enumerator = FileManager.default.enumerator(atPath: folder.path)
    return ((enumerator?.allObjects as? [String]) ?? []).sorted()
}

/// A diarizer that waits until `open()` (or until cancelled) before answering.
private final class SessionImporterGatedDiarizer: SpeakerDiarizer {
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

/// Two speakers alternating every 5 s over the 10 s test audio.
private func sessionImporterDiarizer(error: HolosError? = nil) -> FakeDiarizer {
    FakeDiarizer(outputs: ["mic": FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 5, duration: 10)],
                 error: error)
}

private func sessionImporterCommand(_ file: URL, root: URL, speech: FakeSpeechFactory,
                                    diarizer: (any SpeakerDiarizer)?, transcribe: Bool = true,
                                    postprocess: Bool = true) async throws -> SessionImportCommand.Outcome {
    try await SessionImportCommand.run(
        SessionImportCommand.Request(file: file, name: "Imported", root: root, locale: "en-CA", backend: .speech,
                                     transcribe: transcribe, postprocess: postprocess),
        diarizer: diarizer, makeSpeech: speech.factory, freeSpace: FixedFreeSpace(.max))
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
    #expect(sessionImporterEntries(root) == [session.lastPathComponent], "The staging folder is gone.")
    #expect(session.deletingLastPathComponent().path == root.path)
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

/// The session is built in `.import-<UUID>/` and then moved, so nothing it persists may name the staging folder:
/// `Transcript.source` and every other file name the published `<root>/<id>.holos`.
@Test(.timeLimit(.minutes(1)))
func importPersistsNoStagingPath() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [sessionImporterSegment()])])
    let session = try await sessionImporterImport(wav, root: root, speech: speech, vocabulary: ["Maria Chen"])

    let transcriptID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let transcript = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(transcriptID, in: session))
    #expect(transcript.source == session.path)
    #expect(transcript.source == root.appendingPathComponent(session.lastPathComponent).path)
    let files = sessionImporterTree(session)
    #expect(files.contains { $0.hasSuffix(".json") })
    for relative in files {
        let url = session.appendingPathComponent(relative)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data(ImportStaging.prefix.utf8)) == nil, "\(relative) names the staging folder")
    }
}

/// A discard that fails part-way (any removal or fsync it makes, injected with `AtomicFile.faultPlan`) must leave
/// the ownership marker on a folder that still holds anything, so the next sweep recognizes the folder and removes
/// it. Before, the tree was removed in directory order, and a failure after the marker went left partial audio that
/// no sweep would ever touch.
@Test func discardThatFailsPartWayLeavesTheMarkerForTheNextSweep() throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    func staged() throws -> ImportStaging {
        let staging = try ImportStaging.create(in: root)
        let session = staging.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
        let audio = session.appendingPathComponent("audio/mic", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for index in 1...3 {
            try Data(repeating: 1, count: 64).write(to: audio.appendingPathComponent("00000\(index).caf"))
        }
        try Data("{}".utf8).write(to: session.appendingPathComponent("manifest.json"))
        return staging
    }
    let far = Date(timeIntervalSinceNow: 10 * ImportStaging.unlockedGrace)

    let twin = FaultPlan()
    let clean = try staged()
    #expect(AtomicFile.$faultPlan.withValue(twin) { clean.discard() } == nil)
    #expect(sessionImporterEntries(root).isEmpty)
    let steps = twin.steps.count
    #expect(steps > 8)

    var keptWithMarker = 0
    for failAt in 0..<steps {
        let staging = try staged()
        let folder = staging.url
        let leftover = AtomicFile.$faultPlan.withValue(FaultPlan(failAt: failAt)) { staging.discard() }
        #expect(leftover != nil, "the fault at step \(failAt) (\(twin.steps[failAt])) was not reported")
        guard FileManager.default.fileExists(atPath: folder.path) else { continue }
        let left = sessionImporterTree(folder)
        if left.contains(ImportStaging.markerName) {
            keptWithMarker += 1
            // The next sweep, once the folder is old enough, finishes the removal.
            ImportStaging.sweep(root, now: far)
            #expect(!FileManager.default.fileExists(atPath: folder.path),
                    "the sweep left the folder of the fault at step \(failAt) (\(twin.steps[failAt]))")
        } else {
            // Only a failure on the marker's own folder can lose the marker, and then nothing else is left.
            #expect(left.isEmpty, "the fault at step \(failAt) (\(twin.steps[failAt])) left \(left) unmarked")
            try FileManager.default.removeItem(at: folder)
        }
        #expect(sessionImporterEntries(root).isEmpty)
    }
    #expect(keptWithMarker > 0)

    // The case the review named: the first delete inside the session fails. The marker stays, and the sweep removes
    // the folder.
    let first = try #require(twin.steps.first)
    #expect(first.hasPrefix("unlink ") && !first.contains(ImportStaging.markerName)
            && !first.contains(ImportStaging.lockName))
    let staging = try staged()
    let leftover = AtomicFile.$faultPlan.withValue(FaultPlan(failAt: 0)) { staging.discard() }
    #expect(leftover?.contains("the next import removes it") == true)
    #expect(sessionImporterTree(staging.url).contains(ImportStaging.markerName))
    #expect(sessionImporterTree(staging.url).contains { $0.hasSuffix(".caf") })
    ImportStaging.sweep(root, now: far)
    #expect(sessionImporterEntries(root).isEmpty)
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
        #expect(message.contains("Nothing was imported."))
    }
    #expect(sessionImporterEntries(root).isEmpty)
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
    // While it runs, the import is out of sight: no `.holos` folder in the root, one hidden staging folder.
    #expect(sessionFolders(in: root).isEmpty)
    let staging = sessionImporterStagingFolders(root)
    #expect(staging.count == 1)
    #expect(sessionFolders(in: root.appendingPathComponent(staging.first ?? "missing")).count == 1)
    task.cancel()

    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(sessionImporterEntries(root).isEmpty)
    #expect(await speech.sessions.first?.cancelled == true)
}

@Test(.timeLimit(.minutes(1)))
func importGivesUpOnSpeechThatStopsAnswering() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let speech = FakeSpeechFactory([FakeSpeechScript(finishHangs: true)])
    let timeouts = StopTimeouts(speechFinishBase: .milliseconds(200), speechFinishPerAudioSecond: 0)

    let error = await #expect(throws: HolosError.self) {
        _ = try await SessionImporter.importAudio(from: wav, name: "Imported", root: root, locale: "en-CA",
                                                  backend: .speech, makeSpeech: speech.factory, timeouts: timeouts)
    }
    guard case .unavailable(let message)? = error else {
        Issue.record("Expected unavailable, got \(String(describing: error))")
        return
    }
    #expect(message.contains("could not be transcribed"))
    #expect(message.contains("did not respond within 0.2 s"))
    #expect(message.contains("Nothing was imported."))
    #expect(sessionImporterEntries(root).isEmpty)
    // The stuck session is cancelled without being waited for.
    #expect(await sessionImporterEventually { await speech.sessions.first?.cancelled == true })
}

@Test(.timeLimit(.minutes(1)))
func importRemovesAbandonedImportsButNotRunningOnes() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Killed imports, unchanged for 2 hours: one with its (unlocked) lock file, one without a lock file.
    let killed = try sessionImporterAbandonedStaging(in: root)
    let old = try sessionImporterAbandonedStaging(in: root, lockFile: false)
    // Another import that is running (its lock is held), and recent folders whose lock file is missing or not
    // locked, as an import making or publishing its folder may leave them for a moment.
    let running = try sessionImporterAbandonedStaging(in: root)
    let lock = open(root.appendingPathComponent(running).appendingPathComponent(ImportStaging.lockName).path,
                    O_RDWR | O_CLOEXEC)
    #expect(lock >= 0)
    defer { close(lock) }
    #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
    let starting = try sessionImporterAbandonedStaging(in: root, lockFile: false, age: 0)
    let recentUnlocked = try sessionImporterAbandonedStaging(in: root, age: 0)

    let session = try await sessionImporterImport(wav, root: root, speech: FakeSpeechFactory(), transcribe: false)

    let entries = sessionImporterEntries(root)
    #expect(!entries.contains(killed))
    #expect(!entries.contains(old))
    #expect(entries.contains(running))
    #expect(entries.contains(starting))
    #expect(entries.contains(recentUnlocked))
    #expect(sessionFolders(in: root).map(\.lastPathComponent) == [session.lastPathComponent])
}

@Test(.timeLimit(.minutes(1)))
func importSweepLeavesFoldersHolosDidNotMake() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Folders a user may keep in a `--directory` folder, each with an unlocked lock file and 2 hours old, so
    // each would be removed if its name or contents were not checked.
    let notes = try sessionImporterAbandonedStaging(in: root, name: ".import-notes")
    let unmarked = try sessionImporterAbandonedStaging(in: root, marker: false)
    let unmarkedOld = try sessionImporterAbandonedStaging(in: root, lockFile: false, marker: false)
    let lowercase = try sessionImporterAbandonedStaging(in: root,
                                                        name: ImportStaging.prefix + UUID().uuidString.lowercased())
    let wrongMarker = try sessionImporterAbandonedStaging(in: root, marker: false)
    try Data("holos".utf8).write(to: root.appendingPathComponent(wrongMarker)
        .appendingPathComponent(ImportStaging.markerName))
    // A marker that is a symbolic link to a real marker, and a staging name that is a symbolic link to a folder
    // with a marker: neither is followed.
    let linkedMarker = try sessionImporterAbandonedStaging(in: root, marker: false)
    let realMarker = temp.url.appendingPathComponent("marker")
    try Data(ImportStaging.markerContents).write(to: realMarker)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(linkedMarker).appendingPathComponent(ImportStaging.markerName),
        withDestinationURL: realMarker)
    let target = try sessionImporterAbandonedStaging(in: temp.url, name: "Target")
    let linkedFolder = ImportStaging.prefix + UUID().uuidString
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(linkedFolder),
                                               withDestinationURL: temp.url.appendingPathComponent(target))
    let kept = [notes, unmarked, unmarkedOld, lowercase, wrongMarker, linkedMarker]
    for name in kept {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)],
                                              ofItemAtPath: root.appendingPathComponent(name).path)
    }
    let before = kept.map { sessionImporterTree(root.appendingPathComponent($0)) }
    let targetBefore = sessionImporterTree(temp.url.appendingPathComponent(target))
    // A real abandoned staging folder beside them is still removed.
    let killed = try sessionImporterAbandonedStaging(in: root)

    let session = try await sessionImporterImport(wav, root: root, speech: FakeSpeechFactory(), transcribe: false)

    let entries = sessionImporterEntries(root)
    #expect(!entries.contains(killed))
    #expect(entries.contains(linkedFolder))
    #expect(kept.map { sessionImporterTree(root.appendingPathComponent($0)) } == before)
    #expect(before.allSatisfy { $0.contains { $0.hasSuffix("000001.caf") } })
    #expect(sessionImporterTree(temp.url.appendingPathComponent(target)) == targetBefore)
    #expect(entries.sorted() == (kept + [linkedFolder, session.lastPathComponent]).sorted())
}

@Test func stagingNamesAreExactUppercaseUUIDs() {
    let id = UUID().uuidString
    #expect(ImportStaging.isStagingName(ImportStaging.prefix + id))
    #expect(!ImportStaging.isStagingName(ImportStaging.prefix + id.lowercased()))
    #expect(!ImportStaging.isStagingName(".import-notes"))
    #expect(!ImportStaging.isStagingName(ImportStaging.prefix))
    #expect(!ImportStaging.isStagingName(ImportStaging.prefix + id + "x"))
    #expect(!ImportStaging.isStagingName(id))
}

/// Another import's sweep can run between any two steps of making or publishing a staging folder. At each such point
/// a sweep, even one whose clock is far past `unlockedGrace` (so only the lock and the marker order protect the
/// folder), leaves the staging folder and its session alone.
@Test func sweepAtEveryStepOfCreateAndPublishLeavesTheImportAlone() throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let sessionName = "\(UUID().uuidString).holos"
    var staged: String?
    var seen: [ImportStaging.Step] = []
    func sweepEverywhen(_ step: ImportStaging.Step) {
        seen.append(step)
        let before = sessionImporterEntries(root)
        let trees = before.map { sessionImporterTree(root.appendingPathComponent($0)) }
        ImportStaging.sweep(root)
        ImportStaging.sweep(root, now: Date(timeIntervalSinceNow: 10 * ImportStaging.unlockedGrace))
        #expect(sessionImporterEntries(root) == before, "a sweep after \(step) removed a folder")
        #expect(before.map { sessionImporterTree(root.appendingPathComponent($0)) } == trees,
                "a sweep after \(step) changed a folder")
        if staged == nil { staged = sessionImporterStagingFolders(root).first }
    }

    let staging = try ImportStaging.create(in: root, after: sweepEverywhen)
    #expect(staged == staging.name)
    let audio = staging.url.appendingPathComponent("\(sessionName)/audio/mic", isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 64).write(to: audio.appendingPathComponent("000001.caf"))
    sweepEverywhen(.marked)
    let published = try staging.publish(sessionName, after: sweepEverywhen)

    #expect(Set(seen) == Set(ImportStaging.Step.allCases))
    #expect(sessionImporterEntries(root) == [sessionName])
    #expect(sessionImporterTree(published).contains("audio/mic/000001.caf"))
}

// MARK: - holos session import (import, then labelling)

@Test(.timeLimit(.minutes(1)))
func importCommandLabelsUnderTheImportsLease() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [sessionImporterSegment()])])
    let gated = SessionImporterGatedDiarizer(sessionImporterDiarizer())
    let task = Task { try await sessionImporterCommand(wav, root: root, speech: speech, diarizer: gated) }
    #expect(await sessionImporterEventually { gated.isWaiting })
    let session = try #require(sessionFolders(in: root).first)
    // The import's lease went straight to labelling: no other process could take the session in between.
    #expect(try SessionArchive.isProcessing(at: session))
    #expect(throws: HolosError.self) { try SessionArchive.acquireProcessingLease(at: session, retry: .zero) }
    gated.open()

    let outcome = try await task.value
    #expect(outcome.session.lastPathComponent == session.lastPathComponent)
    #expect(outcome.exitCode == 0)
    #expect(outcome.postProcessing?.state == .succeeded)
    #expect(outcome.summary?.hasSuffix("Exports: \(SessionPaths.exports(outcome.session).path)") == true)
    #expect(try SessionSpeakerStore.readHead(session: outcome.session) != nil)
    #expect(SessionFixtures.exists(SessionPaths.export("json", in: outcome.session)))
    #expect(try !SessionArchive.isProcessing(at: outcome.session), "The lease is released at the end.")
}

@Test(.timeLimit(.minutes(1)))
func importCommandExitCodes() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    func speech() -> FakeSpeechFactory { FakeSpeechFactory([FakeSpeechScript(segments: [sessionImporterSegment()])]) }

    // No speaker models: speaker-less exports and the setup hint, exit 0.
    let withoutModels = try await sessionImporterCommand(wav, root: root, speech: speech(), diarizer: nil)
    #expect(withoutModels.exitCode == 0)
    #expect(withoutModels.summary?.hasPrefix("No speaker labels: speaker models are not installed.") == true)
    #expect(SessionFixtures.exists(SessionPaths.export("txt", in: withoutModels.session)))

    // Labelling fails: the session is kept, exit 3.
    let failing = try await sessionImporterCommand(wav, root: root, speech: speech(),
                                                   diarizer: sessionImporterDiarizer(error: .io("The diarizer broke.")))
    #expect(failing.exitCode == 3)
    #expect(try SessionArchive.readManifest(at: failing.session).status == ArchiveStatus.complete)
    #expect(try !SessionArchive.isProcessing(at: failing.session))

    // Not asked to label: exit 0, no labelling, lease released.
    for (transcribe, postprocess) in [(true, false), (false, true)] {
        let skipped = try await sessionImporterCommand(wav, root: root, speech: speech(),
                                                       diarizer: sessionImporterDiarizer(), transcribe: transcribe,
                                                       postprocess: postprocess)
        #expect(skipped.exitCode == 0)
        #expect(skipped.summary == nil)
        #expect(skipped.postProcessing == nil)
        #expect(!SessionFixtures.exists(SessionPaths.postprocess(skipped.session)))
        #expect(try !SessionArchive.isProcessing(at: skipped.session))
    }
    #expect(sessionFolders(in: root).count == 4)
    #expect(sessionImporterStagingFolders(root).isEmpty)

    // Nothing imported: throws.
    await #expect(throws: HolosError.self) {
        _ = try await sessionImporterCommand(temp.url.appendingPathComponent("missing.wav"), root: root,
                                             speech: speech(), diarizer: nil)
    }
    #expect(sessionFolders(in: root).count == 4)
}

@Test(.timeLimit(.minutes(1)))
func importCommandCancellation() async throws {
    let temp = try TemporaryDirectory("import")
    defer { temp.remove() }
    let wav = try sessionImporterStereoWAV(in: temp.url)
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)

    // Cancelled while importing: nothing is imported, and the error says so.
    let hanging = FakeSpeechFactory([FakeSpeechScript(finishHangs: true)])
    let importing = Task { try await sessionImporterCommand(wav, root: root, speech: hanging, diarizer: nil) }
    #expect(await sessionImporterEventually { await hanging.sessions.first?.finishCalls ?? 0 > 0 })
    importing.cancel()
    let error = await #expect(throws: HolosError.self) { _ = try await importing.value }
    #expect(error?.errorDescription == "The import was cancelled; nothing was imported.")
    #expect(sessionImporterEntries(root).isEmpty)

    // Cancelled while labelling: the imported session is kept, exit 3.
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [sessionImporterSegment()])])
    let gated = SessionImporterGatedDiarizer(sessionImporterDiarizer())
    let labelling = Task { try await sessionImporterCommand(wav, root: root, speech: speech, diarizer: gated) }
    #expect(await sessionImporterEventually { gated.isWaiting })
    labelling.cancel()
    let outcome = try await labelling.value
    #expect(outcome.exitCode == 3)
    #expect(outcome.summary?.hasPrefix("Speaker labelling was cancelled.") == true)
    #expect(try SessionArchive.readManifest(at: outcome.session).status == ArchiveStatus.complete)
    #expect(try SessionArchive.currentTranscriptID(at: outcome.session) != nil)
    #expect(try !SessionArchive.isProcessing(at: outcome.session))
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

/// The message of the `HolosError.invalidInput` or `.unavailable` that `body` throws; nil for no or another error.
private func sessionScorerRefusal(_ body: () throws -> Void) -> (invalid: Bool, message: String)? {
    do {
        try body()
        return nil
    } catch HolosError.invalidInput(let message) {
        return (true, message)
    } catch HolosError.unavailable(let message) {
        return (false, message)
    } catch {
        return nil
    }
}

@Test(.timeLimit(.minutes(1)))
func scoreRejectsTranscriptsWithNoTurnInsideTheAudio() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let session = try await sessionScorerSession(in: temp.url)
    // The fixture's audio is 20 s. A transcript that starts at 30 s is another recording's; one whose only turn
    // starts at 0:20 (Otter rounds down) covers none of the audio. Both used to score as zeros.
    for otter in ["Maria Chen  0:30\nHello.\n", "Maria Chen  0:20\nHello.\n",
                  "Maria Chen  0:00\nHello.\n\nJim Park  0:25\nHi.\n"] {
        let refusal = sessionScorerRefusal { _ = try SessionScorer.score(session: session, otterTranscript: otter) }
        #expect(refusal?.invalid == true, "a transcript outside the audio was scored")
        for word in ["Maria", "Jim", "Hello"] {
            #expect(refusal?.message.contains(word) == false, "the error named a label or transcript word")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func scoreRejectsTimesThatGoBackwards() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let session = try await sessionScorerSession(in: temp.url)
    let otter = "Maria Chen  0:10\nHello.\n\nJim Park  0:05\nHi.\n"
    let refusal = sessionScorerRefusal { _ = try SessionScorer.score(session: session, otterTranscript: otter) }
    #expect(refusal?.invalid == true)
    #expect(refusal?.message.contains("backwards") == true)
}

@Test(.timeLimit(.minutes(1)))
func scoreRejectsLabelsWithoutSpeakerSegments() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let empty = DiarizerOutput(segments: [], centroids: [:], windows: [], processingSeconds: 0)
    try SessionFixtures.writeHeadRun(session: session, transcript: transcript, outputs: ["mic": empty])
    let refusal = sessionScorerRefusal {
        _ = try SessionScorer.score(session: session, otterTranscript: sessionScorerOtterText)
    }
    #expect(refusal?.invalid == false, "labels without segments were scored")
}

@Test(.timeLimit(.minutes(1)))
func scoreRejectsReferenceAndLabelsThatDoNotOverlap() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    // Holos hears one speaker in 0–5 s; Otter's only turn runs 10–20 s.
    try SessionFixtures.writeHeadRun(
        session: session, transcript: transcript,
        outputs: ["mic": FakeDiarizer.alternating(speakers: ["S1"], turnSeconds: 5, duration: 5)])
    let refusal = sessionScorerRefusal {
        _ = try SessionScorer.score(session: session, otterTranscript: "Maria Chen  0:10\nHello.\n")
    }
    #expect(refusal?.invalid == true, "disjoint reference and labels were scored")
    #expect(refusal?.message.contains("overlap") == true)
}

@Test(.timeLimit(.minutes(1)))
func scoreRejectsACollarThatCoversEveryTurn() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    let session = try await sessionScorerSession(in: temp.url)
    // The fixture's Otter turns are 5 s long; a 3 s collar around each boundary leaves nothing to score.
    let refusal = sessionScorerRefusal {
        _ = try SessionScorer.score(session: session, otterTranscript: sessionScorerOtterText, collar: 3)
    }
    #expect(refusal?.invalid == true, "a transcript with every turn inside the collar was scored")
    #expect(refusal?.message.contains("collar") == true)
}

@Test(.timeLimit(.minutes(1)))
func scoreReportsTurnAgreementAsNotComparableWithoutLabelledTurns() async throws {
    let temp = try TemporaryDirectory("score")
    defer { temp.remove() }
    // No words, so the run has speaker segments but no labelled turns.
    let transcript = SessionFixtures.transcript([])
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                     outputs: ["mic": SessionFixtures.alternatingOutput()])
    let report = try SessionScorer.score(session: session, otterTranscript: sessionScorerOtterText)
    #expect(report.agreementConfusion == 0)
    #expect(report.comparedSeconds > 15)
    #expect(report.turnAgreementConfusion == nil)
    #expect(report.turnComparedSeconds == 0)
    #expect(report.summaryLines.contains { $0.hasSuffix("labelled turns: not comparable (no labelled turn overlaps Otter's turns)") })

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(report), as: UTF8.self)
    #expect(!json.contains("turnAgreementConfusion"))
    let decoded = try JSONDecoder().decode(SessionScorer.Report.self, from: Data(json.utf8))
    #expect(decoded == report)
}
