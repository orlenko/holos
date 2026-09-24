import Foundation
import AVFoundation
import Testing
import HolosCore
@testable import HolosStorage

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-storage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func archive(in root: URL) throws -> SessionArchive {
    try SessionArchive.create(root: root, name: "A safe display name / with punctuation",
                              source: .microphoneAndSystem, locale: "en-CA", backend: .speech)
}

private func writeCAF(at url: URL, frames: Int = 64, sampleRate: Double = 48_000) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let samples = buffer.floatChannelData else { throw HolosError.invalidInput("Test audio allocation failed.") }
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames { samples[0][index] = 0.1 }
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
    try file?.write(from: buffer)
    file = nil
}

@Test func archiveRoundTripAndRecoveryInspection() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let directory = writer.directory
    #expect(directory.lastPathComponent == "\(writer.id).holos")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio/mic").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio/system").path))
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)

    let audio = directory.appendingPathComponent("audio/mic/000001.caf")
    try Data([0x63, 0x61, 0x66, 0x66, 1, 2, 3]).write(to: audio)
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/000001.caf",
                                         start: 0, end: 1, sampleRate: 48_000,
                                         channels: 1, frameCount: 48_000))
    try await writer.recordEvent(kind: "captureStarted", details: ["track": "mic"])
    let transcript = Transcript(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                source: "mic", locale: "en-CA", backend: .speech,
                                segments: [.init(start: 0, end: 1, text: "Hello world")])
    try await writer.saveTranscript(transcript)
    try await writer.finish(status: "complete")

    let manifest = try SessionArchive.readManifest(at: directory)
    #expect(manifest.name == "A safe display name / with punctuation")
    #expect(manifest.status == "complete")
    #expect(manifest.chunks.count == 1)
    #expect(manifest.chunks[0].sha256?.count == 64)
    let decoded = try JSONDecoder.holos.decode(Transcript.self,
        from: Data(contentsOf: directory.appendingPathComponent("transcripts/\(transcript.id).json")))
    #expect(decoded == transcript)
    #expect(try String(contentsOf: directory.appendingPathComponent("exports/transcript.txt"),
                       encoding: .utf8) == "Hello world\n")
    let first = try SessionArchive.inspectRecovery(at: directory)
    let second = try SessionArchive.inspectRecovery(at: directory)
    #expect(first == second)
    #expect(!first.needsAttention)
    #expect(first.events.map(\.sequence) == [1])
}

@Test func refusesTraversalDuplicateSnapshotsAndConcurrentWriter() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    #expect(throws: Error.self) { try SessionArchive.open(at: writer.directory) }
    let traversal = AudioChunkRecord(track: "mic", relativePath: "audio/mic/../secret.caf",
                                     start: 0, end: 1, sampleRate: 48_000,
                                     channels: 1, frameCount: 48_000)
    await #expect(throws: Error.self) { try await writer.registerChunk(traversal) }
    let transcript = Transcript(id: "revision1", source: "mic", locale: "en-CA", backend: .speech)
    try await writer.saveTranscript(transcript)
    await #expect(throws: Error.self) { try await writer.saveTranscript(transcript) }
    let badTranscript = Transcript(id: "../outside", source: "mic", locale: "en-CA", backend: .speech)
    await #expect(throws: Error.self) { try await writer.saveTranscript(badTranscript) }
    try await writer.finish(status: "complete")
}

@Test func interruptedManifestAndTornJournalAreReportedWithoutMutation() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let directory = writer.directory
    let orphan = directory.appendingPathComponent("audio/system/000002.caf")
    try Data([1, 2, 3]).write(to: orphan)
    let partialManifest = directory.appendingPathComponent(".interrupted.tmp")
    try Data("{\"status\":\"broken\"".utf8).write(to: partialManifest)
    try await writer.recordEvent(kind: "started", details: [:])
    let journal = directory.appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"sequence\":2".utf8))
    try handle.close()
    let before = try Data(contentsOf: journal)
    let first = try SessionArchive.inspectRecovery(at: directory)
    let second = try SessionArchive.inspectRecovery(at: directory)
    #expect(first == second)
    #expect(first.manifest?.status == "recording")
    #expect(first.tornFinalJournalLine)
    #expect(first.events.map(\.sequence) == [1])
    #expect(first.unindexedChunks == ["audio/system/000002.caf"])
    #expect(try Data(contentsOf: journal) == before)
}

@Test func missingAndCorruptChunksAreReported() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let first = writer.directory.appendingPathComponent("audio/mic/first.caf")
    let second = writer.directory.appendingPathComponent("audio/mic/second.caf")
    try Data([1, 2, 3]).write(to: first)
    try Data([4, 5, 6]).write(to: second)
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/first.caf",
                                         start: 0, end: 1, sampleRate: 1, channels: 1, frameCount: 1))
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/second.caf",
                                         start: 1, end: 2, sampleRate: 1, channels: 1, frameCount: 1))
    try await writer.finish(status: "complete")
    try FileManager.default.removeItem(at: first)
    try Data([7, 8]).write(to: second)
    let report = try SessionArchive.inspectRecovery(at: writer.directory)
    #expect(report.missingChunks == ["audio/mic/first.caf"])
    #expect(report.corruptChunks == ["audio/mic/second.caf"])
    #expect(report.needsAttention)
    let manifestBefore = try Data(contentsOf: writer.directory.appendingPathComponent("manifest.json"))
    await #expect(throws: Error.self) { try await SessionArchive.recover(at: writer.directory) }
    #expect(try Data(contentsOf: writer.directory.appendingPathComponent("manifest.json")) == manifestBefore)
}

@Test func unsafeManifestPathIsRejectedWithoutReadingOutsideArchive() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    var manifest = try SessionArchive.readManifest(at: writer.directory)
    manifest.chunks = [.init(track: "mic", relativePath: "audio/mic/../../outside.caf",
                             start: 0, end: 1, sampleRate: 1, channels: 1, frameCount: 1)]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: writer.directory.appendingPathComponent("manifest.json"))
    #expect(throws: Error.self) { try SessionArchive.readManifest(at: writer.directory) }
    let report = try SessionArchive.inspectRecovery(at: writer.directory)
    #expect(report.manifest == nil)
    #expect(report.manifestError != nil)
}

@Test func activeLockAndProcessingStatus() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    #expect(try SessionArchive.isActive(at: writer.directory))
    await #expect(throws: Error.self) { try await SessionArchive.recover(at: writer.directory) }
    try await writer.setStatus("processing")
    #expect(try SessionArchive.readManifest(at: writer.directory).status == "processing")
    #expect(try SessionArchive.isActive(at: writer.directory))
    try await writer.finish(status: "complete")
    #expect(try !SessionArchive.isActive(at: writer.directory))
}

private func makeStaleArchive(in root: URL) async throws -> URL {
    let writer = try archive(in: root)
    let directory = writer.directory
    let path = "audio/mic/000001.caf"
    try await writer.recordEvent(kind: "chunkOpened", details: [
        "track": "mic", "relativePath": path, "start": "2.5",
        "sampleRate": "48000", "channels": "1",
    ])
    try writeCAF(at: directory.appendingPathComponent(path))
    try writeCAF(at: directory.appendingPathComponent("audio/mic/no-metadata.caf"))
    try await writer.setStatus("processing")
    return directory
}

@Test func recoveryPreservesJournalAndReconstructsTimedCAFOnly() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await makeStaleArchive(in: root)
    #expect(try !SessionArchive.isActive(at: directory))
    let journal = directory.appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"sequence\":2".utf8))
    try handle.close()
    let original = try Data(contentsOf: journal)
    let originalAudio = try Data(contentsOf: directory.appendingPathComponent("audio/mic/000001.caf"))

    let first = try await SessionArchive.recover(at: directory)
    #expect(first.manifest?.status == "interrupted")
    #expect(first.manifest?.chunks.count == 1)
    #expect(first.manifest?.chunks[0].relativePath == "audio/mic/000001.caf")
    #expect(first.manifest?.chunks[0].start == 2.5)
    #expect(first.manifest?.chunks[0].frameCount == 64)
    #expect(first.manifest?.chunks[0].end == 2.5 + 64.0 / 48_000)
    #expect(first.manifest?.chunks[0].sha256?.count == 64)
    #expect(first.unrecoveredChunks == ["audio/mic/no-metadata.caf"])
    #expect(first.unindexedChunks == ["audio/mic/no-metadata.caf"])
    #expect(!first.tornFinalJournalLine)
    #expect(first.events.map(\.sequence) == [1, 2])
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("events.before-recovery-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == original)
    #expect(try Data(contentsOf: directory.appendingPathComponent("audio/mic/000001.caf")) == originalAudio)

    let second = try await SessionArchive.recover(at: directory)
    #expect(second.manifest == first.manifest)
    #expect(second.events == first.events)
    #expect(second.unrecoveredChunks == first.unrecoveredChunks)
    #expect(try Data(contentsOf: backups[0]) == original)
    #expect(try Data(contentsOf: directory.appendingPathComponent("audio/mic/000001.caf")) == originalAudio)
}

@Test func markdownExportPreservesSegmentTimeTrackAndSpeakerLabel() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let transcript = Transcript(source: "meeting", locale: "en-CA", backend: .speech,
        segments: [
            .init(start: 1.25, end: 2.5, text: "First phrase", track: "mic", speakerID: "spk-1"),
            .init(start: 3, end: 4.125, text: "Second phrase", track: "system"),
        ])
    try await writer.saveTranscript(transcript)
    let markdown = try String(contentsOf: writer.directory.appendingPathComponent("exports/transcript.md"),
                              encoding: .utf8)
    #expect(markdown.contains("[00:00:01.250–00:00:02.500] Source: mic"))
    #expect(markdown.contains("Speaker label (not verified identity): spk-1"))
    #expect(markdown.contains("[00:00:03.000–00:00:04.125] Source: system"))
    #expect(markdown.contains("First phrase"))
    #expect(markdown.contains("Second phrase"))
    let plain = try String(contentsOf: writer.directory.appendingPathComponent("exports/transcript.txt"),
                           encoding: .utf8)
    #expect(plain == "First phrase Second phrase\n")
}

// MARK: - PR6: tolerant journal, group commit, leases, maintenance, integrity of new files

private func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func fileSize(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
}

private func isInvalidInput(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

/// A finished archive with one registered chunk and two events.
private func finishedArchive(in root: URL) async throws -> URL {
    let writer = try archive(in: root)
    let path = "audio/mic/000001.caf"
    try writeCAF(at: writer.directory.appendingPathComponent(path))
    try await writer.registerChunk(.init(track: "mic", relativePath: path, start: 0, end: 64.0 / 48_000,
                                         sampleRate: 48_000, channels: 1, frameCount: 64))
    try await writer.recordEvent(kind: MeetingEventKind.chunkOpened, details: ["track": "mic", "relativePath": path])
    try await writer.recordEvent(kind: MeetingEventKind.captureStopped, details: ["reason": StopReason.requested.rawValue])
    try await writer.finish(status: ArchiveStatus.complete)
    return writer.directory
}

/// An archive left `recording` with events written and no live writer (the process "exited").
private func abandonedRecording(in root: URL, events: Int) async throws -> URL {
    let writer = try archive(in: root)
    for index in 1...events { try await writer.recordEvent(kind: "tick", details: ["index": "\(index)"]) }
    return writer.directory
}

@Test func failedAppendLeavesNoPartialLine() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let journal = SessionPaths.events(writer.directory)
    try await writer.recordEvent(kind: "first", details: [:])
    let size = try fileSize(journal)
    await #expect(throws: HolosError.self) {
        try await AtomicFile.$appendFailureAfterBytes.withValue(10) {
            try await writer.recordEvent(kind: "second", details: ["text": "never saved"])
        }
    }
    #expect(try fileSize(journal) == size)
    try await writer.recordEvent(kind: "third", details: [:])
    try await writer.finish(status: ArchiveStatus.complete)
    let events = try SessionArchive.readEvents(at: writer.directory)
    #expect(events.events.map(\.sequence) == [1, 2])
    #expect(events.events.map(\.kind) == ["first", "third"])
    #expect(events.unreadableLines == 0)
    #expect(!events.tornTail)
}

@Test func corruptMiddleEventLineIsSkippedAndCounted() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await abandonedRecording(in: root, events: 1)
    let journal = SessionPaths.events(directory)
    try appendRaw("{\"sequence\":2,\"kind\":garbage\n", to: journal)
    try appendRaw(String(decoding: try HolosJSON.line(ArchiveEvent(sequence: 2, at: Date(timeIntervalSince1970: 0),
                                                                   kind: "tick", details: [:])), as: UTF8.self),
                  to: journal)

    let read = try SessionArchive.readEvents(at: directory)
    #expect(read.events.map(\.sequence) == [1, 2])
    #expect(read.unreadableLines == 1)
    #expect(!read.tornTail)
    let report = try SessionArchive.inspectRecovery(at: directory)
    #expect(report.events.count == 2)
    #expect(report.unreadableEventLines == 1)
    #expect(!report.needsAttention)

    let reopened = try SessionArchive.open(at: directory)
    try await reopened.recordEvent(kind: "after", details: [:])
    try await reopened.finish(status: ArchiveStatus.complete)
    let after = try SessionArchive.readEvents(at: directory)
    #expect(after.events.map(\.sequence) == [1, 2, 3])
    #expect(after.unreadableLines == 1)
}

@Test func outOfOrderEventLinesAreSkipped() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await abandonedRecording(in: root, events: 2)
    let journal = SessionPaths.events(directory)
    func line(_ sequence: Int, _ kind: String) throws -> String {
        String(decoding: try HolosJSON.line(ArchiveEvent(sequence: sequence, at: Date(timeIntervalSince1970: 0),
                                                         kind: kind, details: [:])), as: UTF8.self)
    }
    // A lower sequence number decodes but cannot follow event 2.
    try appendRaw(try line(1, "backwards"), to: journal)
    let read = try SessionArchive.readEvents(at: directory)
    #expect(read.events.map(\.kind) == ["tick", "tick"])
    #expect(read.unreadableLines == 1)
}

@Test func repeatedSequenceFromAnOlderBuildIsKept() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await abandonedRecording(in: root, events: 1)
    let journal = SessionPaths.events(directory)
    // Builds before PR6 reused a sequence after an append whose fsync failed; both lines are real events.
    try appendRaw(String(decoding: try HolosJSON.line(ArchiveEvent(
        sequence: 1, at: Date(timeIntervalSince1970: 0), kind: MeetingEventKind.chunkOpened,
        details: ["relativePath": "audio/mic/000001.caf"])), as: UTF8.self), to: journal)
    let read = try SessionArchive.readEvents(at: directory)
    #expect(read.events.map(\.sequence) == [1, 1])
    #expect(read.events.map(\.kind) == ["tick", MeetingEventKind.chunkOpened])
    #expect(read.unreadableLines == 0)

    let reopened = try SessionArchive.open(at: directory)
    try await reopened.recordEvent(kind: "after", details: [:])
    try await reopened.finish(status: ArchiveStatus.complete)
    #expect(try SessionArchive.readEvents(at: directory).events.map(\.sequence) == [1, 1, 2])
}

/// A journal whose only line is one event with `sequence`, in an archive left `recording`.
private func abandonedRecording(in root: URL, onlySequence sequence: Int) throws -> URL {
    let directory = try archive(in: root).directory
    let line = try HolosJSON.line(ArchiveEvent(sequence: sequence, at: Date(timeIntervalSince1970: 0),
                                               kind: "tick", details: [:]))
    try AtomicFile.write(line, to: SessionPaths.events(directory))
    return directory
}

@Test func exhaustedSequenceIsUnreadableAndDoesNotTrap() async throws {
    // A damaged journal starting at Int.max used to be readable, and every opener trapped on `last + 1`.
    for opener in ["open", "maintenance", "recover"] {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try abandonedRecording(in: root, onlySequence: Int.max)
        let read = try SessionArchive.readEvents(at: directory)
        #expect(read.events.isEmpty)
        #expect(read.unreadableLines == 1)
        switch opener {
        case "open":
            let reopened = try SessionArchive.open(at: directory)
            try await reopened.recordEvent(kind: "after", details: [:])
            try await reopened.finish(status: ArchiveStatus.complete)
        case "maintenance":
            _ = try await SessionArchive.recover(at: directory)
            let lease = try SessionArchive.acquireProcessingLease(at: directory)
            let maintenance = try SessionArchive.openForMaintenance(at: directory, lease: lease)
            try await maintenance.recordEvent(kind: "after", details: [:])
            try await maintenance.finish(status: ArchiveStatus.recovered)
            lease.release()
        default:
            let report = try await SessionArchive.recover(at: directory)
            #expect(report.manifest?.status == ArchiveStatus.interrupted)
            #expect(report.events.map(\.kind) == [MeetingEventKind.archiveRecovered])
        }
        #expect(try SessionArchive.readEvents(at: directory).events.last?.sequence ?? 0 < 10)
    }
}

@Test func lastSequenceNumberIsNeverAssigned() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try abandonedRecording(in: root, onlySequence: Int.max - 1)
    #expect(try SessionArchive.readEvents(at: directory).events.map(\.sequence) == [Int.max - 1])

    let reopened = try SessionArchive.open(at: directory)
    await #expect(throws: HolosError.self) { try await reopened.recordEvent(kind: "after", details: [:]) }
    try await reopened.finish(status: ArchiveStatus.complete)
    #expect(try SessionArchive.readEvents(at: directory).events.map(\.sequence) == [Int.max - 1])
}

@Test func recoveryOfAnExhaustedJournalSkipsItsEvent() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try abandonedRecording(in: root, onlySequence: Int.max - 1)
    let report = try await SessionArchive.recover(at: directory)
    #expect(report.manifest?.status == ArchiveStatus.interrupted)
    #expect(report.events.map(\.sequence) == [Int.max - 1])
    #expect(report.unreadableEventLines == 0)
}

/// Journal fsyncs (`events.jsonl`) counted by the AtomicFile test hook.
private func journalSyncs(_ counter: FileSyncCounter) -> Int { counter.count("events.jsonl") }

@Test func groupCommitSyncsOnlyWhenDue() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let counter = FileSyncCounter()
    try await AtomicFile.$fileSyncCounter.withValue(counter) {
        await writer.setJournalSync(.interval(seconds: 60))
        try await writer.recordEvent(kind: "first", details: [:])
        #expect(journalSyncs(counter) == 1)
        for index in 1...3 { try await writer.recordEvent(kind: "tick", details: ["index": "\(index)"]) }
        #expect(journalSyncs(counter) == 1)
        try await writer.recordEvent(kind: MeetingEventKind.captureStopped, details: [:])
        #expect(journalSyncs(counter) == 2)
        try await writer.recordEvent(kind: MeetingEventKind.archiveRecovered, details: [:])
        try await writer.recordEvent(kind: MeetingEventKind.transcriptRebuilt, details: [:])
        #expect(journalSyncs(counter) == 4)
        try await writer.recordEvent(kind: "late", details: [:])
        #expect(journalSyncs(counter) == 4)
        try await writer.finish(status: ArchiveStatus.complete)
        #expect(journalSyncs(counter) == 5)
    }
}

@Test func everyEventModeSyncsEachEvent() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let counter = FileSyncCounter()
    try await AtomicFile.$fileSyncCounter.withValue(counter) {
        for index in 1...3 { try await writer.recordEvent(kind: "tick", details: ["index": "\(index)"]) }
        #expect(journalSyncs(counter) == 3)
        try await writer.finish(status: ArchiveStatus.complete)
        #expect(journalSyncs(counter) == 3)
    }
}

@Test func groupCommitSyncsAfterTheInterval() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let counter = FileSyncCounter()
    try await AtomicFile.$fileSyncCounter.withValue(counter) {
        await writer.setJournalSync(.interval(seconds: 0.5))
        try await writer.recordEvent(kind: "first", details: [:])
        try await writer.recordEvent(kind: "second", details: [:])
        #expect(journalSyncs(counter) == 1)
        // The scheduled flush syncs the dirty journal without another event.
        let deadline = ContinuousClock.now + .seconds(5)
        while journalSyncs(counter) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(journalSyncs(counter) == 2)
        try await writer.finish(status: ArchiveStatus.complete)
        // Nothing was dirty at finish.
        #expect(journalSyncs(counter) == 2)
    }
}

@Test func hugeGroupCommitIntervalIsClamped() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let counter = FileSyncCounter()
    try await AtomicFile.$fileSyncCounter.withValue(counter) {
        await writer.setJournalSync(.interval(seconds: 1e300))
        try await writer.recordEvent(kind: "first", details: [:])
        try await writer.recordEvent(kind: "second", details: [:])
        #expect(journalSyncs(counter) == 1)
        try await writer.finish(status: ArchiveStatus.complete)
        #expect(journalSyncs(counter) == 2)
    }
    #expect(try SessionArchive.readEvents(at: writer.directory).events.count == 2)
}

@Test func saveTranscriptCanBeRetriedAfterThePointerFails() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let first = Transcript(source: "mic", locale: "en-CA", backend: .speech)
    try await writer.saveTranscript(first, writeLegacyExports: false)
    let pointer = SessionPaths.transcriptPointer(writer.directory)
    try FileManager.default.removeItem(at: pointer)
    try FileManager.default.createDirectory(at: pointer, withIntermediateDirectories: false)

    let second = Transcript(source: "mic", locale: "en-CA", backend: .speech,
                            segments: [.init(start: 0, end: 1, text: "Hi")])
    await #expect(throws: HolosError.self) { try await writer.saveTranscript(second, writeLegacyExports: false) }
    try FileManager.default.removeItem(at: pointer)
    try await writer.saveTranscript(second, writeLegacyExports: false)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == second.id)
    // Once current, the same revision is refused; a different one with the same ID always is.
    await #expect(throws: HolosError.self) { try await writer.saveTranscript(second, writeLegacyExports: false) }
    var changed = second
    changed.segments = []
    await #expect(throws: HolosError.self) { try await writer.saveTranscript(changed, writeLegacyExports: false) }
    try await writer.finish(status: ArchiveStatus.complete)
}

@Test func saveTranscriptCanBeRetriedAfterALegacyExportFails() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let first = Transcript(source: "mic", locale: "en-CA", backend: .speech,
                           segments: [.init(start: 0, end: 1, text: "First")])
    try await writer.saveTranscript(first)
    let markdown = SessionPaths.export("md", in: writer.directory)
    try FileManager.default.removeItem(at: markdown)
    try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: false)

    let second = Transcript(source: "mic", locale: "en-CA", backend: .speech,
                            segments: [.init(start: 0, end: 1, text: "Second")])
    await #expect(throws: (any Error).self) { try await writer.saveTranscript(second) }
    // The pointer does not advance past exports that were not written.
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == first.id)

    try FileManager.default.removeItem(at: markdown)
    try await writer.saveTranscript(second)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == second.id)
    let text = try String(contentsOf: SessionPaths.export("txt", in: writer.directory), encoding: .utf8)
    #expect(text.contains("Second"))
    let rendered = try String(contentsOf: markdown, encoding: .utf8)
    #expect(rendered.contains("Second"))
    try await writer.finish(status: ArchiveStatus.complete)
}

@Test func interruptedSessionWithDeletedAudioRecovers() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await abandonedRecording(in: root, events: 1)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("audio"))
    try AtomicFile.writeJSON(["schemaVersion": 1], to: SessionPaths.audioDeleted(directory))

    let report = try await SessionArchive.recover(at: directory)
    #expect(report.manifest?.status == ArchiveStatus.interrupted)
    #expect(!report.needsAttention)
    let lease = try SessionArchive.acquireProcessingLease(at: directory)
    let maintenance = try SessionArchive.openForMaintenance(at: directory, lease: lease)
    try await maintenance.finish(status: ArchiveStatus.recovered)
    lease.release()
}

@Test func recoverLeavesNoLockFileInAFolderThatIsNotASession() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: HolosError.self) { try await SessionArchive.recover(at: root) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func groupCommitKeepsEveryEvent() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    await writer.setJournalSync(.interval(seconds: 1))
    for index in 1...3 { try await writer.recordEvent(kind: "tick", details: ["index": "\(index)"]) }
    try await writer.recordEvent(kind: MeetingEventKind.captureStopped, details: [:])
    try await writer.recordEvent(kind: "late", details: [:])
    try await writer.finish(status: ArchiveStatus.complete)
    let text = try String(contentsOf: SessionPaths.events(writer.directory), encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    let lines = text.split(separator: "\n")
    #expect(lines.count == 5)
    for line in lines { #expect(throws: Never.self) { try JSONDecoder.holos.decode(ArchiveEvent.self, from: Data(line.utf8)) } }
    #expect(try SessionArchive.readEvents(at: writer.directory).events.map(\.sequence) == [1, 2, 3, 4, 5])
}

@Test func groupCommitFlushesAfterTheInterval() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    await writer.setJournalSync(.interval(seconds: 0.05))
    try await writer.recordEvent(kind: "first", details: [:])
    try await writer.recordEvent(kind: "second", details: [:])
    try await Task.sleep(for: .milliseconds(150))
    try await writer.recordEvent(kind: "third", details: [:])
    await writer.setJournalSync(.everyEvent)
    try await writer.recordEvent(kind: "fourth", details: [:])
    try await writer.finish(status: ArchiveStatus.complete)
    #expect(try SessionArchive.readEvents(at: writer.directory).events.map(\.kind) == ["first", "second", "third", "fourth"])
}

@Test func maintenanceOpenNeedsMatchingLease() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await finishedArchive(in: root)
    let second = try await finishedArchive(in: root)
    let otherLease = try SessionArchive.acquireProcessingLease(at: second)
    defer { otherLease.release() }
    let wrong = #expect(throws: HolosError.self) { try SessionArchive.openForMaintenance(at: first, lease: otherLease) }
    #expect(isInvalidInput(wrong))
    #expect(try !SessionArchive.isActive(at: first))

    let lease = try SessionArchive.acquireProcessingLease(at: first)
    let maintenance = try SessionArchive.openForMaintenance(at: first, lease: lease)
    #expect(try SessionArchive.isActive(at: first))
    #expect(throws: HolosError.self) { try SessionArchive.openForMaintenance(at: first, lease: lease) }
    try await maintenance.recordEvent(kind: MeetingEventKind.transcriptRebuilt, details: ["transcriptID": "T"])
    try await maintenance.saveTranscript(Transcript(source: "mic", locale: "en-CA", backend: .speech),
                                         writeLegacyExports: false)
    try await maintenance.finish(status: ArchiveStatus.recovered)
    #expect(try !SessionArchive.isActive(at: first))
    #expect(try SessionArchive.isProcessing(at: first))
    #expect(try SessionArchive.readManifest(at: first).status == ArchiveStatus.recovered)
    #expect(try SessionArchive.readEvents(at: first).events.map(\.sequence) == [1, 2, 3])
    lease.release()

    let released = #expect(throws: HolosError.self) { try SessionArchive.openForMaintenance(at: first, lease: lease) }
    #expect(isInvalidInput(released))
}

@Test func maintenanceOpenRefusesARecordingArchive() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await abandonedRecording(in: root, events: 1)
    let lease = try SessionArchive.acquireProcessingLease(at: directory)
    defer { lease.release() }
    let error = #expect(throws: HolosError.self) { try SessionArchive.openForMaintenance(at: directory, lease: lease) }
    #expect(isInvalidInput(error))
    #expect(try !SessionArchive.isActive(at: directory))
}

@Test func maintenanceOpenRepairsTornTail() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await finishedArchive(in: root)
    let journal = SessionPaths.events(directory)
    try appendRaw("{\"sequence\":3,\"ki", to: journal)
    let torn = try Data(contentsOf: journal)
    #expect(try SessionArchive.readEvents(at: directory).tornTail)

    let lease = try SessionArchive.acquireProcessingLease(at: directory)
    defer { lease.release() }
    let maintenance = try SessionArchive.openForMaintenance(at: directory, lease: lease)
    try await maintenance.recordEvent(kind: MeetingEventKind.transcriptRebuilt, details: [:])
    try await maintenance.finish(status: ArchiveStatus.recovered)

    let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("events.torn-") }
    #expect(backups.count == 1)
    if let backup = backups.first { #expect(try Data(contentsOf: directory.appendingPathComponent(backup)) == torn) }
    let read = try SessionArchive.readEvents(at: directory)
    #expect(read.events.map(\.sequence) == [1, 2, 3])
    #expect(read.events.last?.kind == MeetingEventKind.transcriptRebuilt)
    #expect(!read.tornTail)
    #expect(read.unreadableLines == 0)
}

@Test func recoverRefusedWhileLeaseHeldElsewhere() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await makeStaleArchive(in: root)
    let manifest = try Data(contentsOf: SessionPaths.manifest(directory))
    let journal = try Data(contentsOf: SessionPaths.events(directory))
    let fd = Darwin.open(directory.appendingPathComponent(".processing.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    try #require(fd >= 0)
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    await #expect(throws: HolosError.self) { try await SessionArchive.recover(at: directory) }
    #expect(try Data(contentsOf: SessionPaths.manifest(directory)) == manifest)
    #expect(try Data(contentsOf: SessionPaths.events(directory)) == journal)
    flock(fd, LOCK_UN)
    Darwin.close(fd)

    let report = try await SessionArchive.recover(at: directory)
    #expect(report.manifest?.status == ArchiveStatus.interrupted)
    #expect(try !SessionArchive.isProcessing(at: directory))
}

@Test func recoverUnderTheCallersLease() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await makeStaleArchive(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: directory)
    let report = try await SessionArchive.recover(at: directory, lease: lease)
    #expect(report.manifest?.status == ArchiveStatus.interrupted)
    #expect(try SessionArchive.isProcessing(at: directory))
    #expect(try !SessionArchive.isActive(at: directory))
    let maintenance = try SessionArchive.openForMaintenance(at: directory, lease: lease)
    try await maintenance.finish(status: ArchiveStatus.recovered)
    lease.release()
}

@Test func oldArchiveInspectsClean() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let directory = writer.directory
    try Data([1, 2, 3]).write(to: directory.appendingPathComponent("audio/mic/000001.caf"))
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/000001.caf",
                                         start: 0, end: 1, sampleRate: 1, channels: 1, frameCount: 1))
    let transcript = Transcript(createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: "mic",
                                locale: "en-CA", backend: .speech, segments: [.init(start: 0, end: 1, text: "Hi")])
    try await writer.saveTranscript(transcript)
    try await writer.finish(status: ArchiveStatus.complete)

    // Rewrite the files the way builds before PR6 wrote them: escaped slashes, no pointer, no new folders.
    let old = JSONEncoder()
    old.dateEncodingStrategy = .iso8601
    old.outputFormatting = [.sortedKeys, .prettyPrinted]
    try old.encode(try SessionArchive.readManifest(at: directory)).write(to: SessionPaths.manifest(directory))
    #expect(try String(contentsOf: SessionPaths.manifest(directory), encoding: .utf8).contains(#"audio\/mic"#))
    try FileManager.default.removeItem(at: SessionPaths.transcriptPointer(directory))
    old.outputFormatting = [.sortedKeys]
    var line = try old.encode(ArchiveEvent(sequence: 1, at: Date(timeIntervalSince1970: 1_700_000_000),
                                           kind: MeetingEventKind.captureStarted, details: ["hostTimeOrigin": "1.5"]))
    line.append(0x0A)
    try line.write(to: SessionPaths.events(directory))

    let report = try SessionArchive.inspectRecovery(at: directory)
    #expect(!report.needsAttention)
    #expect(report.events.count == 1)
    #expect(report.manifest?.chunks.count == 1)
    #expect(try SessionArchive.currentTranscriptID(at: directory) == transcript.id)
    #expect(try !SessionArchive.isActive(at: directory))
    #expect(try !SessionArchive.isProcessing(at: directory))
    #expect(try SessionSpeakerStore.readHead(session: directory) == nil)
    #expect(try SessionSpeakerStore.readEdits(session: directory) == EditJournal())
    #expect(try SessionSpeakerStore.runIDs(session: directory) == [])
}

@Test func newFoldersDoNotAffectIntegrity() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await finishedArchive(in: root)
    let manifest = try SessionArchive.readManifest(at: directory)
    let lease = try SessionArchive.acquireProcessingLease(at: directory)
    let maintenance = try SessionArchive.openForMaintenance(at: directory, lease: lease)
    try await maintenance.saveTranscript(Transcript(source: "mic", locale: "en-CA", backend: .speech),
                                         writeLegacyExports: false)
    try await maintenance.finish(status: ArchiveStatus.complete)
    lease.release()

    let run = DiarizationRun(sessionID: manifest.id, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                             transcriptID: UUID().uuidString, engine: nil,
                             alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: [], speakers: [], turns: [])
    try SessionArchive.withSpeakerLock(at: directory) {
        try SessionSpeakerStore.writeRun(run, session: directory)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: directory)
        try SessionSpeakerStore.appendEdits([SpeakerEdit(baseRunID: run.id, source: "cli",
                                                         action: .rename(speakerID: "mic:me", name: "Me"))],
                                            session: directory)
    }
    try AtomicFile.ensurePrivateDirectory(SessionPaths.derived(directory))
    try Data([1, 2, 3]).write(to: SessionPaths.derived(directory).appendingPathComponent("x.caf"))
    try AtomicFile.writeJSON(RecorderStatus(sessionID: manifest.id, name: manifest.name, pid: 1, phase: .exited,
                                            sequence: 1, startedAt: Date(), updatedAt: Date(), source: manifest.source),
                             to: SessionPaths.status(directory))
    try AtomicFile.ensurePrivateDirectory(SessionPaths.controlDirectory(directory))
    try AtomicFile.writeJSON(ControlRequest(sessionID: manifest.id, command: .stop, sender: "cli"),
                             to: SessionPaths.controlDirectory(directory).appendingPathComponent("\(UUID().uuidString).json"))
    try AtomicFile.writeJSON(MeetingInfo(sessionID: manifest.id, mode: .inPerson, othersInRoom: false),
                             to: SessionPaths.meetingInfo(directory))
    try AtomicFile.writeJSON(PostProcessingRecord(sessionID: manifest.id, state: .succeeded, pid: 1,
                                                  startedAt: Date(), updatedAt: Date()),
                             to: SessionPaths.postprocess(directory))

    let report = try SessionArchive.inspectRecovery(at: directory)
    #expect(!report.needsAttention)
    #expect(report.unindexedChunks.isEmpty)
    #expect(report.unreadableEventLines == 0)
}

@Test func deletedAudioIsExpected() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await finishedArchive(in: root)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("audio"))
    let withoutMarker = try SessionArchive.inspectRecovery(at: directory)
    #expect(withoutMarker.missingChunks == ["audio/mic/000001.caf"])
    #expect(withoutMarker.needsAttention)

    try AtomicFile.writeJSON(["schemaVersion": 1], to: SessionPaths.audioDeleted(directory))
    let report = try SessionArchive.inspectRecovery(at: directory)
    #expect(report.missingChunks.isEmpty)
    #expect(!report.needsAttention)
    #expect(try !SessionArchive.isActive(at: directory))

    // Maintenance still works without audio folders.
    let lease = try SessionArchive.acquireProcessingLease(at: directory)
    let maintenance = try SessionArchive.openForMaintenance(at: directory, lease: lease)
    try await maintenance.recordEvent(kind: "audioDeleted", details: [:])
    try await maintenance.finish(status: ArchiveStatus.complete)
    lease.release()
}

@Test func createWithExplicitID() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    let writer = try SessionArchive.create(root: root, name: "Explicit", source: .microphone,
                                           locale: "en-CA", backend: .speech, id: id)
    #expect(writer.id == id)
    #expect(writer.directory.lastPathComponent == "\(id).holos")
    #expect(writer.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    try await writer.finish(status: ArchiveStatus.complete)
    #expect(try SessionArchive.readManifest(at: writer.directory).id == id)
}

@Test func createRefusesExistingOrInvalidID() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    let first = try SessionArchive.create(root: root, name: "First", source: .microphone,
                                          locale: "en-CA", backend: .speech, id: id)
    let manifest = try Data(contentsOf: SessionPaths.manifest(first.directory))
    for bad in [id, "../x", "", id.lowercased(), "not-a-uuid"] {
        let error = #expect(throws: HolosError.self) {
            try SessionArchive.create(root: root, name: "Second", source: .microphone,
                                      locale: "en-CA", backend: .speech, id: bad)
        }
        #expect(isInvalidInput(error), "\(bad)")
    }
    #expect(try Data(contentsOf: SessionPaths.manifest(first.directory)) == manifest)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["\(id).holos"])
    #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("x.holos").path))
    try await first.finish(status: ArchiveStatus.complete)
}

@Test func readEventsSkipsHashing() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await finishedArchive(in: root)
    try Data([9, 9, 9]).write(to: directory.appendingPathComponent("audio/mic/000001.caf"))
    #expect(try SessionArchive.inspectRecovery(at: directory).corruptChunks == ["audio/mic/000001.caf"])
    let journal = try SessionArchive.readEvents(at: directory)
    #expect(journal.events.map(\.kind) == [MeetingEventKind.chunkOpened, MeetingEventKind.captureStopped])
    #expect(!journal.tornTail)
    #expect(journal.unreadableLines == 0)
}

private extension JSONDecoder {
    static var holos: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
