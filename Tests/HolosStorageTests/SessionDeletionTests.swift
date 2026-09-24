import Darwin
import Foundation
import HolosCore
@testable import HolosStorage
import Synchronization
import Testing

// Delete Audio and Delete Meeting (docs/meeting-design.md §4.13, §5.6 PR3). The catalog side of Delete Audio
// (`SessionSummary.audioDeleted`) is checked in HolosMeetingTests/SessionCatalogTests, where the catalog lives.

private let deletionDate = Date(timeIntervalSince1970: 1_790_000_000)

private func deletionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-deletion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct DeletionFixture {
    var session: URL
    var id: String
    var transcriptID: String
    var runID: String
}

/// A finished session with two mic chunks and one system chunk (arbitrary bytes, registered with their hashes), a
/// current transcript, a head run, evaluation voice data, a render in derived/, and read-only exports.
private func deletionSession(in root: URL) async throws -> DeletionFixture {
    let archive = try SessionArchive.create(root: root, name: "Council", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    let session = archive.directory
    for (track, number, start) in [("mic", 1, 0.0), ("mic", 2, 30.0), ("system", 1, 0.0)] {
        let path = String(format: "audio/%@/%06d.caf", track, number)
        try Data(repeating: UInt8(number), count: 4_096).write(to: session.appendingPathComponent(path))
        try await archive.registerChunk(AudioChunkRecord(track: track, relativePath: path, start: start,
                                                         end: start + 30, sampleRate: 48_000, channels: 1,
                                                         frameCount: 1_440_000))
    }
    let transcript = Transcript(createdAt: deletionDate, source: "fixture", locale: "en-CA", backend: .speech,
                                segments: [TranscriptSegment(start: 1, end: 4, text: "Hello there", track: "system")])
    try await archive.saveTranscript(transcript, writeLegacyExports: false)
    try await archive.finish(status: ArchiveStatus.complete)

    let run = DiarizationRun(
        id: UUID().uuidString, sessionID: archive.id, createdAt: deletionDate, transcriptID: transcript.id,
        engine: nil, alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized)],
        speakers: [SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])],
        turns: [])
    let voice = SessionVoiceData(runID: run.id, sessionID: archive.id, createdAt: deletionDate,
                                 embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
                                 centroids: ["system:S1": FloatVector([1, 0])], turnEmbeddings: [])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        try SessionSpeakerStore.writeVoiceData(voice, session: session)
    }
    try AtomicFile.ensurePrivateDirectory(SessionPaths.derived(session))
    try Data(repeating: 7, count: 2_048).write(to: SessionPaths.render(track: "system", in: session))
    for ext in ["md", "txt", "json"] {
        try AtomicFile.write(Data("export \(ext)\n".utf8), to: SessionPaths.export(ext, in: session), permissions: 0o400)
    }
    return DeletionFixture(session: session, id: archive.id, transcriptID: transcript.id, runID: run.id)
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

private func isInvalidInput(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

private func isUnavailable(_ error: HolosError?) -> Bool {
    if case .unavailable? = error { return true }
    return false
}

/// Every regular file under `folder` by relative path, with its bytes.
private func deletionFiles(in folder: URL) -> [String: Data] {
    let prefix = folder.standardizedFileURL.path + "/"
    var result: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        result[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
    }
    return result
}

@Test func deleteAudioKeepsTranscript() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await deletionSession(in: root)
    let session = fixture.session
    let manifestBefore = try SessionArchive.readManifest(at: session)
    let eventsBefore = try Data(contentsOf: SessionPaths.events(session))

    let lease = try SessionArchive.acquireProcessingLease(at: session)
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    #expect(lease.isHeld, "The caller's lease is not released by the deletion.")
    lease.release()

    #expect(!exists(session.appendingPathComponent("audio")))
    #expect(!exists(SessionPaths.derived(session)))
    #expect(!exists(SessionPaths.voiceDirectory(session)))
    // Kept: the transcript, the speaker labels, the exports, the manifest, and the journal.
    #expect(try SessionArchive.currentTranscriptID(at: session) == fixture.transcriptID)
    #expect(try SessionSpeakerStore.readRun(id: fixture.runID, session: session).id == fixture.runID)
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == fixture.runID)
    for ext in ["md", "txt", "json"] {
        #expect(try Data(contentsOf: SessionPaths.export(ext, in: session)) == Data("export \(ext)\n".utf8))
    }
    #expect(try SessionArchive.readManifest(at: session) == manifestBefore)
    #expect(try Data(contentsOf: SessionPaths.events(session)) == eventsBefore)

    let marker = try AtomicFile.readJSON(AudioDeletedRecord.self, from: SessionPaths.audioDeleted(session))
    #expect(marker.schemaVersion == 1)
    #expect(marker.sessionID == fixture.id)
    #expect(marker.chunkCount == 3)
    #expect(marker.seconds == 60, "The longest track: two 30 s mic chunks.")
    #expect(abs(marker.deletedAt.timeIntervalSinceNow) < 60)
    var info = stat()
    #expect(lstat(SessionPaths.audioDeleted(session).path, &info) == 0 && info.st_mode & 0o777 == 0o600)

    let report = try SessionArchive.inspectRecovery(at: session)
    #expect(!report.needsAttention)
    #expect(report.missingChunks.isEmpty)
    #expect(try !SessionArchive.isProcessing(at: session))
    #expect(try !SessionArchive.isActive(at: session))
}

@Test func deleteAudioCanBeRepeatedAndKeepsTheFirstRecord() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await deletionSession(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    let first = try Data(contentsOf: SessionPaths.audioDeleted(session))
    // A render left by a later run, then Delete Audio again: it goes, and the first record stays as written.
    try AtomicFile.ensurePrivateDirectory(SessionPaths.derived(session))
    try Data([1, 2, 3]).write(to: SessionPaths.render(track: "mic", in: session))
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    #expect(!exists(SessionPaths.derived(session)))
    #expect(try Data(contentsOf: SessionPaths.audioDeleted(session)) == first)
    #expect(!(try SessionArchive.inspectRecovery(at: session).needsAttention))
}

@Test func deleteAudioReadsAnExistingMarker() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await deletionSession(in: root)
    let session = fixture.session
    let marker = SessionPaths.audioDeleted(session)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }

    // A marker from a newer Holos is refused before anything is removed.
    var object = try #require(try JSONSerialization.jsonObject(with: HolosJSON.encoder().encode(
        AudioDeletedRecord(sessionID: fixture.id, chunkCount: 3, seconds: 60))) as? [String: Any])
    object["schemaVersion"] = 2
    let newer = try JSONSerialization.data(withJSONObject: object)
    try newer.write(to: marker)
    let before = deletionFiles(in: session)
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionDeletion.deleteAudio(session: session, lease: lease)
    }))
    #expect(deletionFiles(in: session) == before, "Nothing was removed or written.")
    #expect(isUnavailable(#expect(throws: HolosError.self) { try SessionArchive.inspectRecovery(at: session) }))

    // A damaged marker, or one of another session, is replaced by this session's record.
    let foreign = try HolosJSON.encoder().encode(AudioDeletedRecord(sessionID: UUID().uuidString, chunkCount: 9,
                                                                    seconds: 9))
    for data in [Data("not json".utf8), foreign] {
        try FileManager.default.removeItem(at: marker)
        try data.write(to: marker)
        #expect(try !AudioDeletedRecord.isDeleted(session: session, sessionID: fixture.id))
        try SessionDeletion.deleteAudio(session: session, lease: lease)
        let record = try #require(try AudioDeletedRecord.read(session: session, sessionID: fixture.id))
        #expect(record.sessionID == fixture.id && record.chunkCount == 3)
    }
}

@Test func deleteRefusedWhileRecording() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A recorder holds the writer lock of a session that has audio and voice data.
    let recorder = try SessionArchive.create(root: root, name: "Live", source: .microphone, locale: "en-CA",
                                             backend: .speech)
    let session = recorder.directory
    try Data(repeating: 1, count: 1_024).write(to: session.appendingPathComponent("audio/mic/000001.caf"))
    try AtomicFile.ensurePrivateDirectory(SessionPaths.derived(session))
    try Data([1]).write(to: SessionPaths.render(track: "mic", in: session))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let before = deletionFiles(in: session)
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionDeletion.deleteAudio(session: session, lease: lease)
    }))
    let trashed = SharedURLs()
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionDeletion.moveToTrash(session: session, lease: lease, logDirectory: logs) { trashed.append($0) }
    }))
    #expect(trashed.urls.isEmpty)
    #expect(deletionFiles(in: session) == before, "Nothing was removed or written.")
    #expect(!exists(SessionPaths.audioDeleted(session)))
    try await recorder.finish(status: ArchiveStatus.complete)
}

/// URLs a fake trash was handed.
private final class SharedURLs: Sendable {
    private let state = Mutex<[URL]>([])
    var urls: [URL] { state.withLock { $0 } }
    func append(_ url: URL) { state.withLock { $0.append(url) } }
}

@Test func moveToTrashRemovesRecorderLog() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await deletionSession(in: root)
    let session = fixture.session
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("recorder-\(fixture.id).log")
    let otherLog = logs.appendingPathComponent("recorder-\(UUID().uuidString).log")
    try Data("recorder output\n".utf8).write(to: log)
    try Data("another meeting\n".utf8).write(to: otherLog)
    let trashFolder = root.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)

    let trashed = SharedURLs()
    var voiceAtTrashTime: Bool?
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    try SessionDeletion.moveToTrash(session: session, lease: lease, logDirectory: logs) { url in
        trashed.append(url)
        voiceAtTrashTime = exists(SessionPaths.voiceDirectory(url))
        try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
    }
    lease.release()

    #expect(trashed.urls == [session])
    #expect(voiceAtTrashTime == false, "Voice data is deleted before the folder goes to the Trash.")
    #expect(!exists(session))
    let inTrash = trashFolder.appendingPathComponent(session.lastPathComponent)
    #expect(try SessionArchive.currentTranscriptID(at: inTrash) == fixture.transcriptID, "The rest can be restored.")
    #expect(exists(inTrash.appendingPathComponent("audio/mic/000001.caf")))
    #expect(!exists(log), "The meeting's recorder log is deleted.")
    #expect(exists(otherLog), "Other meetings' logs stay.")
}

@Test func moveToTrashWithoutALogFolderOrManifest() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await deletionSession(in: root)
    let session = fixture.session
    // A damaged manifest: the session can still be deleted, and its log is found by the folder name.
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("recorder-\(fixture.id).log")
    try Data("x".utf8).write(to: log)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    try Data("not json".utf8).write(to: SessionPaths.manifest(session))
    let trashed = SharedURLs()
    try SessionDeletion.moveToTrash(session: session, lease: lease, logDirectory: logs) { trashed.append($0) }
    #expect(trashed.urls == [session])
    #expect(!exists(log))

    // No log folder at all is not an error.
    let second = try await deletionSession(in: root).session
    let secondLease = try SessionArchive.acquireProcessingLease(at: second)
    defer { secondLease.release() }
    try SessionDeletion.moveToTrash(session: second, lease: secondLease,
                                    logDirectory: root.appendingPathComponent("NoLogs")) { trashed.append($0) }
    #expect(trashed.urls == [session, second])
}

@Test func moveToTrashWithoutManifestDeletesAFolderThatCannotTakeALease() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A crash between SessionArchive.create's mkdir and its manifest write: a <UUID>.holos with only audio/mic.
    let id = UUID().uuidString
    let session = root.appendingPathComponent("\(id).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: session.appendingPathComponent("audio/mic"),
                                            withIntermediateDirectories: true)
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionArchive.acquireProcessingLease(at: session)
    }), "The lease path refuses it.")
    #expect(try SessionDeletion.lacksManifest(session: session))
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("recorder-\(id).log")
    try Data("x".utf8).write(to: log)

    let trashed = SharedURLs()
    try SessionDeletion.moveToTrashWithoutManifest(session: session, logDirectory: logs) { trashed.append($0) }
    #expect(trashed.urls == [session])
    #expect(!exists(log))
    #expect(try !SessionArchive.isProcessing(at: session), "Its locks are released.")
    #expect(try !SessionArchive.isActive(at: session))
}

@Test func moveToTrashWithoutManifestRefusesASessionOrABusyFolder() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    let trashed = SharedURLs()
    // A session with a manifest goes through the lease path.
    let session = try await deletionSession(in: root).session
    #expect(try !SessionDeletion.lacksManifest(session: session))
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionDeletion.moveToTrashWithoutManifest(session: session, logDirectory: logs) { trashed.append($0) }
    }))
    // A recorder that holds the writer lock of a folder whose manifest is not written yet.
    let recorder = try SessionArchive.create(root: root, name: "Live", source: .microphone, locale: "en-CA",
                                             backend: .speech)
    try FileManager.default.removeItem(at: SessionPaths.manifest(recorder.directory))
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionDeletion.moveToTrashWithoutManifest(session: recorder.directory, logDirectory: logs) {
            trashed.append($0)
        }
    }))
    #expect(trashed.urls.isEmpty)
    #expect(exists(recorder.directory))
    #expect(try !SessionArchive.isProcessing(at: recorder.directory), "The lease it took is released.")
    withExtendedLifetime(recorder) {}
}

/// A session lock file held from a descriptor of its own, as another process would hold it. `letGo()` is idempotent.
private final class DeletionLockHolder: Sendable {
    private let fd: Mutex<Int32>

    init(_ name: String, in session: URL) throws {
        let fd = Darwin.open(session.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        self.fd = Mutex(fd)
    }

    func letGo() {
        let fd = self.fd.withLock { value -> Int32 in
            let current = value
            value = -1
            return current
        }
        if fd >= 0 {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }
}

/// Answers seen from inside a deletion.
private final class DeletionProbes: Sendable {
    private let values = Mutex<[Bool]>([])
    func append(_ value: Bool) { values.withLock { $0.append(value) } }
    var all: [Bool] { values.withLock { $0 } }
}

@Test func moveToTrashHoldsTheSpeakerLockThroughTheTrash() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await deletionSession(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    var speakerLockHeld: Bool?
    var editRefused = false
    try SessionDeletion.moveToTrash(session: session, lease: lease, logDirectory: root) { url in
        speakerLockHeld = try SessionLockFile.isHeld(SessionLockFile.speakers, in: url)
        // A speaker edit or export regeneration (which take only the speaker lock) cannot start meanwhile.
        do {
            try SessionArchive.withSpeakerLock(at: url, timeout: .zero) {}
        } catch HolosError.unavailable {
            editRefused = true
        }
    }
    #expect(speakerLockHeld == true, "The speaker lock is held while the folder is handed to the Trash.")
    #expect(editRefused)
    #expect(try !SessionLockFile.isHeld(SessionLockFile.speakers, in: session), "It is released afterwards.")

    // The same for a folder without a manifest.
    let bare = root.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
    var bareSpeakerLockHeld: Bool?
    try SessionDeletion.moveToTrashWithoutManifest(session: bare, logDirectory: root) { url in
        bareSpeakerLockHeld = try SessionLockFile.isHeld(SessionLockFile.speakers, in: url)
    }
    #expect(bareSpeakerLockHeld == true)
    #expect(try !SessionLockFile.isHeld(SessionLockFile.speakers, in: bare))
}

@Test func moveToTrashWithoutManifestWaitsForTheSpeakerLock() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bare = root.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
    let holder = try DeletionLockHolder(SessionLockFile.speakers, in: bare)
    defer { holder.letGo() }
    let trashed = SharedURLs()
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionDeletion.moveToTrashWithoutManifest(session: bare, logDirectory: root) { trashed.append($0) }
    }))
    #expect(trashed.urls.isEmpty)
}

@Test func deletionKeepsARecorderFromReopeningTheSession() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A `recording` archive whose recorder is gone: its writer lock is free, so `SessionArchive.open` could reopen it.
    func staleSession() throws -> URL {
        let session = try SessionArchive.create(root: root, name: "Stale", source: .microphone, locale: "en-CA",
                                                backend: .speech).directory
        try Data(repeating: 1, count: 1_024).write(to: session.appendingPathComponent("audio/mic/000001.caf"))
        #expect(try !SessionArchive.isActive(at: session))
        return session
    }
    let session = try staleSession()
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }

    // Delete Audio: seen from the moment it waits for a busy speaker lock, the writer lock is held.
    let speakers = try DeletionLockHolder(SessionLockFile.speakers, in: session)
    defer { speakers.letGo() }
    let probes = DeletionProbes()
    try SessionLockFile.$onContention.withValue({
        probes.append((try? SessionArchive.isActive(at: session)) ?? false)
        speakers.letGo()
    }) {
        try SessionDeletion.deleteAudio(session: session, lease: lease)
    }
    #expect(probes.all == [true], "No recorder can reopen the session while its audio is deleted.")
    #expect(try !SessionArchive.isActive(at: session), "The writer lock is released afterwards.")

    // Delete Meeting: a recorder that tries to reopen the session while it is handed to the Trash is refused. (A
    // second stale session: the first has no audio/ folder now, which `open` refuses for its layout alone.)
    let other = try staleSession()
    let otherLease = try SessionArchive.acquireProcessingLease(at: other)
    defer { otherLease.release() }
    var reopenError: HolosError?
    try SessionDeletion.moveToTrash(session: other, lease: otherLease, logDirectory: root) { url in
        reopenError = #expect(throws: HolosError.self) { try SessionArchive.open(at: url) }
    }
    #expect(isUnavailable(reopenError))
    #expect(try !SessionArchive.isActive(at: other))
}

@Test func moveToTrashKeepsTheFolderWhenTrashFails() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await deletionSession(in: root)
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("recorder-\(fixture.id).log")
    try Data("x".utf8).write(to: log)
    let lease = try SessionArchive.acquireProcessingLease(at: fixture.session)
    defer { lease.release() }
    #expect(throws: HolosError.self) {
        try SessionDeletion.moveToTrash(session: fixture.session, lease: lease, logDirectory: logs) { _ in
            throw HolosError.io("The volume has no Trash.")
        }
    }
    #expect(exists(fixture.session.appendingPathComponent("audio/mic/000001.caf")))
    #expect(exists(log), "The log stays with a meeting that was not deleted.")
}

@Test func deletionNeedsThisSessionsLease() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await deletionSession(in: root).session
    let other = try await deletionSession(in: root).session
    let otherLease = try SessionArchive.acquireProcessingLease(at: other)
    defer { otherLease.release() }
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionDeletion.deleteAudio(session: session, lease: otherLease)
    }))
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionDeletion.moveToTrash(session: session, lease: otherLease, logDirectory: root) { _ in
            Issue.record("A session must not be trashed under another session's lease.")
        }
    }))
    let released = try SessionArchive.acquireProcessingLease(at: session)
    released.release()
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionDeletion.deleteAudio(session: session, lease: released)
    }))
    #expect(exists(session.appendingPathComponent("audio/mic/000001.caf")))
    #expect(!exists(SessionPaths.audioDeleted(session)))
}

@Test func deleteAudioNeverFollowsSymbolicLinks() async throws {
    let root = try deletionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: outside.appendingPathComponent("mic"), withIntermediateDirectories: true)
    let precious = outside.appendingPathComponent("mic/precious.caf")
    try Data("keep".utf8).write(to: precious)
    let session = try await deletionSession(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }

    // audio/ and derived/ replaced by links to a folder outside: the links go, the targets stay.
    try fm.removeItem(at: session.appendingPathComponent("audio"))
    try fm.createSymbolicLink(at: session.appendingPathComponent("audio"), withDestinationURL: outside)
    try fm.removeItem(at: SessionPaths.derived(session))
    try fm.createSymbolicLink(at: SessionPaths.derived(session), withDestinationURL: outside)
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    #expect(!exists(session.appendingPathComponent("audio")))
    #expect(!exists(SessionPaths.derived(session)))
    #expect(try Data(contentsOf: precious) == Data("keep".utf8))

    // A link inside audio/ is removed, not followed.
    try AtomicFile.ensurePrivateDirectory(session.appendingPathComponent("audio/mic", isDirectory: true))
    try fm.createSymbolicLink(at: session.appendingPathComponent("audio/mic/000009.caf"), withDestinationURL: precious)
    try fm.createSymbolicLink(at: session.appendingPathComponent("audio/elsewhere"), withDestinationURL: outside)
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    #expect(!exists(session.appendingPathComponent("audio")))
    #expect(try Data(contentsOf: precious) == Data("keep".utf8))

    // speakers/ replaced by a link: refused before anything is removed, the target untouched.
    try AtomicFile.ensurePrivateDirectory(session.appendingPathComponent("audio/mic", isDirectory: true))
    let chunk = session.appendingPathComponent("audio/mic/000001.caf")
    try Data([1]).write(to: chunk)
    let speakers = session.appendingPathComponent("speakers")
    let movedSpeakers = root.appendingPathComponent("speakers-real", isDirectory: true)
    try fm.moveItem(at: speakers, to: movedSpeakers)
    try fm.createDirectory(at: outside.appendingPathComponent("voice"), withIntermediateDirectories: true)
    let outsideVoice = outside.appendingPathComponent("voice/run.json")
    try Data("{}".utf8).write(to: outsideVoice)
    try fm.createSymbolicLink(at: speakers, withDestinationURL: outside)
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionDeletion.deleteAudio(session: session, lease: lease)
    }))
    #expect(exists(outsideVoice))
    #expect(exists(chunk), "Audio is not deleted when the voice data cannot be.")
}

@Test func savedSecondsIsTheLongestTrack() {
    func chunk(_ track: String, _ start: Double, _ end: Double) -> AudioChunkRecord {
        AudioChunkRecord(track: track, relativePath: "audio/\(track)/\(UUID().uuidString).caf", start: start, end: end,
                         sampleRate: 48_000, channels: 1, frameCount: 1)
    }
    var manifest = SessionManifest(id: UUID().uuidString, name: "M", createdAt: deletionDate, source: .microphoneAndSystem,
                                   locale: "en-CA", backend: .speech, status: ArchiveStatus.complete)
    #expect(manifest.savedSeconds == 0)
    // A paused mic track (0–30, 90–120) is 60 s saved even though it spans 120 s; the system track has 45 s.
    manifest.chunks = [chunk("mic", 0, 30), chunk("mic", 90, 120), chunk("system", 0, 45)]
    #expect(manifest.savedSeconds == 60)
}
