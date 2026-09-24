import Foundation
import AVFoundation
import Darwin
import Synchronization
import Testing
import HolosCore
@testable import HolosStorage

// Session operations that used to go through a path after the folder chain had been checked: backup exclusion
// of speakers/voice, the processing lease's folder check, and recovery's audio reads. Each test swaps a file or
// folder for another (or for a symbolic link) at the moment the old path-based step ran.

private func swapTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-swap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func swapFinishedSession(in root: URL) async throws -> (session: URL, id: String) {
    let archive = try SessionArchive.create(root: root, name: "Swap", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return (archive.directory, archive.id)
}

private func swapIsInvalidInput(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

private func isExcludedFromBackup(_ url: URL) throws -> Bool {
    try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        ?? false
}

private func backupAttribute(_ url: URL) -> Data? {
    var buffer = [UInt8](repeating: 0, count: 1024)
    let size = getxattr(url.path, SessionSpeakerStore.backupExclusionAttribute, &buffer, buffer.count, 0,
                        XATTR_NOFOLLOW)
    return size < 0 ? nil : Data(buffer.prefix(size))
}

/// Replaces `folder` by a symbolic link to `target`, keeping the real folder at `moved`.
private func swapFolderForLink(_ folder: URL, movedTo moved: URL, target: URL) {
    let fm = FileManager.default
    try? fm.moveItem(at: folder, to: moved)
    try? fm.createSymbolicLink(at: folder, withDestinationURL: target)
}

private func swapWriteCAF(at url: URL, frames: Int) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let samples = buffer.floatChannelData else { throw HolosError.invalidInput("Test audio allocation failed.") }
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames { samples[0][index] = 0.1 }
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
    try file?.write(from: buffer)
    file = nil
}

/// True the first time only.
private final class Once: Sendable {
    private let fired = Mutex(false)
    func claim() -> Bool { fired.withLock { value in defer { value = true }; return !value } }
}

// MARK: - Backup exclusion

@Test func backupExclusionWritesTheAttributeFoundationWrites() throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let byFoundation = root.appendingPathComponent("foundation", isDirectory: true)
    let byDescriptor = root.appendingPathComponent("descriptor", isDirectory: true)
    try FileManager.default.createDirectory(at: byFoundation, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: byDescriptor, withIntermediateDirectories: false)
    var url = byFoundation
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)

    let fd = Darwin.open(byDescriptor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try #require(fd >= 0)
    defer { Darwin.close(fd) }
    try SessionSpeakerStore.excludeFromBackup(fd, name: "descriptor")
    #expect(backupAttribute(byDescriptor) == backupAttribute(byFoundation))
    #expect(backupAttribute(byDescriptor) == SessionSpeakerStore.backupExclusionValue)
    #expect(try isExcludedFromBackup(byDescriptor))
}

// The review case: speakers/voice is swapped for a link after the chain opened it and before the exclusion was
// set. The path-based `setResourceValues` followed the link and marked the target outside the session.
@Test func backupExclusionIsSetOnTheOpenedFolderNeverOnASwappedLink() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await swapFinishedSession(in: root)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let voice = SessionPaths.voiceDirectory(session)
    let moved = SessionPaths.speakers(session).appendingPathComponent("voice-real", isDirectory: true)
    let data = SessionVoiceData(runID: UUID().uuidString, sessionID: sessionID,
                                createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
                                centroids: [:], turnEmbeddings: [])

    let error = #expect(throws: HolosError.self) {
        try SessionSpeakerStore.$beforeBackupExclusion.withValue({ url in
            if url.lastPathComponent == "voice" { swapFolderForLink(voice, movedTo: moved, target: outside) }
        }) {
            try SessionSpeakerStore.writeVoiceData(data, session: session)
        }
    }
    // The voice file write that follows refuses the link; the target outside was never changed.
    #expect(swapIsInvalidInput(error))
    #expect(try !isExcludedFromBackup(outside))
    #expect(backupAttribute(outside) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    // The exclusion landed on the real folder the chain opened.
    #expect(try isExcludedFromBackup(moved))
}

// MARK: - Processing lease

@Test func leaseComparesTheFolderItOpensWithoutFollowingALink() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, _) = try await swapFinishedSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    try lease.require(for: session)
    try lease.require(for: URL(fileURLWithPath: session.path + "/"))

    // A link to the session folder is the same folder by `stat`, but it is refused.
    let link = root.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: session)
    #expect(swapIsInvalidInput(#expect(throws: HolosError.self) { try lease.require(for: link) }))

    // The session folder is swapped for a link to itself (moved away), then for another real folder.
    let moved = root.appendingPathComponent("moved.holos", isDirectory: true)
    swapFolderForLink(session, movedTo: moved, target: moved)
    #expect(swapIsInvalidInput(#expect(throws: HolosError.self) { try lease.require(for: session) }))
    try lease.require(for: moved)
    try FileManager.default.removeItem(at: session)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
    let error = #expect(throws: HolosError.self) { try lease.require(for: session) }
    #expect(swapIsInvalidInput(error))
    if case .invalidInput(let message)? = error { #expect(message.contains("another session")) }
}

// MARK: - Recovery audio reads

/// A stale archive whose only chunk, audio/mic/000001.caf (64 frames), is not in the manifest yet.
private func swapStaleArchive(in root: URL) async throws -> URL {
    let writer = try SessionArchive.create(root: root, name: "Swap", source: .microphoneAndSystem,
                                           locale: "en-CA", backend: .speech)
    try await writer.recordEvent(kind: "chunkOpened", details: [
        "track": "mic", "relativePath": "audio/mic/000001.caf", "start": "0",
        "sampleRate": "48000", "channels": "1",
    ])
    try swapWriteCAF(at: writer.directory.appendingPathComponent("audio/mic/000001.caf"), frames: 64)
    try await writer.setStatus(ArchiveStatus.processing)
    return writer.directory
}

@Test func recoveryReadsChunkAudioThroughItsDescriptor() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await swapStaleArchive(in: root)
    let report = try await SessionArchive.recover(at: directory)
    let chunk = try #require(report.manifest?.chunks.first)
    #expect(chunk.frameCount == 64)
    #expect(chunk.sampleRate == 48_000)
    #expect(chunk.channels == 1)
    #expect(report.corruptChunks.isEmpty)
    #expect(report.unrecoveredChunks.isEmpty)
    let reading = try ChunkFile.read(at: directory.appendingPathComponent(chunk.relativePath))
    #expect(reading == ChunkReading(sampleRate: 48_000, channels: 1, frames: 64, sha256: try #require(chunk.sha256)))
}

// audio/mic is swapped for a link just before the chunk is opened: the path-based AVAudioFile read followed it.
@Test func recoveryNeverReadsAChunkThroughASwappedFolder() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await swapStaleArchive(in: root)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try swapWriteCAF(at: outside.appendingPathComponent("000001.caf"), frames: 128)
    let mic = directory.appendingPathComponent("audio/mic", isDirectory: true)
    let moved = directory.appendingPathComponent("audio/mic-real", isDirectory: true)
    let once = Once()

    let report = try await ChunkFile.$readHook.withValue({ url, stage in
        if stage == .beforeOpen, url.lastPathComponent == "000001.caf", once.claim() {
            swapFolderForLink(mic, movedTo: moved, target: outside)
        }
    }) {
        try await SessionArchive.recover(at: directory)
    }
    #expect(report.unrecoveredChunks == ["audio/mic/000001.caf"])
    #expect(report.manifest?.chunks.isEmpty == true)
}

// The chunk is replaced by another file after it was opened: its format and hash describe the file that was
// opened, which is no longer at the path, so it is refused rather than indexed under that path.
@Test func recoveryRefusesAChunkReplacedWhileItIsRead() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await swapStaleArchive(in: root)
    let replacement = root.appendingPathComponent("replacement.caf")
    try swapWriteCAF(at: replacement, frames: 128)
    let chunkURL = directory.appendingPathComponent("audio/mic/000001.caf")
    let once = Once()

    let report = try await ChunkFile.$readHook.withValue({ url, stage in
        if stage == .afterOpen, url.lastPathComponent == "000001.caf", once.claim() {
            _ = rename(replacement.path, chunkURL.path)
        }
    }) {
        try await SessionArchive.recover(at: directory)
    }
    #expect(report.unrecoveredChunks == ["audio/mic/000001.caf"])
    #expect(report.manifest?.chunks.isEmpty == true)
}

// audio/mic is swapped for a link to a folder holding a same-named chunk after the chunk was opened.
@Test func recoveryRefusesAChunkWhoseFolderIsSwappedWhileItIsRead() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await swapStaleArchive(in: root)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try swapWriteCAF(at: outside.appendingPathComponent("000001.caf"), frames: 64)
    let mic = directory.appendingPathComponent("audio/mic", isDirectory: true)
    let moved = directory.appendingPathComponent("audio/mic-real", isDirectory: true)
    let once = Once()

    let report = try await ChunkFile.$readHook.withValue({ url, stage in
        if stage == .afterOpen, url.lastPathComponent == "000001.caf", once.claim() {
            swapFolderForLink(mic, movedTo: moved, target: outside)
        }
    }) {
        try await SessionArchive.recover(at: directory)
    }
    #expect(report.unrecoveredChunks == ["audio/mic/000001.caf"])
    #expect(report.manifest?.chunks.isEmpty == true)
}

/// `create(inEmptyFolder:)` writes the session into the folder it was given only when the path later writes take
/// reaches that folder. Here the folder was renamed away and another put at its name: nothing is written into
/// either, and the call throws. Otherwise the session is made in the open folder, and its processing lease can be
/// taken through that folder's descriptor.
@Test func createInEmptyFolderRefusesAPathThatNoLongerReachesTheFolder() async throws {
    let root = try swapTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    #expect(rootFD >= 0)
    defer { close(rootFD) }

    let name = "\(UUID().uuidString).holos"
    let directory = root.appendingPathComponent(name, isDirectory: true)
    #expect(mkdirat(rootFD, name, 0o700) == 0)
    let folder = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    #expect(folder >= 0)
    defer { close(folder) }
    let moved = root.appendingPathComponent("moved", isDirectory: true)
    try fm.moveItem(at: directory, to: moved)
    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    #expect(throws: HolosError.self) {
        _ = try SessionArchive.create(inEmptyFolder: folder, directory: directory, name: "Swap", source: .microphone,
                                      locale: "en-CA", backend: .speech)
    }
    #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(try fm.contentsOfDirectory(atPath: moved.path).isEmpty)

    try fm.removeItem(at: directory)
    try fm.moveItem(at: moved, to: directory)
    let archive = try SessionArchive.create(inEmptyFolder: folder, directory: directory, name: "Swap",
                                            source: .microphone, locale: "en-CA", backend: .speech)
    let lease = try SessionArchive.acquireProcessingLease(inFolder: folder, session: directory, retry: .zero)
    defer { lease.release() }
    try lease.require(for: directory)
    try await archive.finish(status: ArchiveStatus.complete)
    #expect(try SessionArchive.readManifest(at: directory).name == "Swap")
}
