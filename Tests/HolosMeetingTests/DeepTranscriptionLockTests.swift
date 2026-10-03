import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// The lock the deep transcription pass holds for its whole life (docs/meeting-design.md §4.16, "App"). Each open
// file description holds its own flock, so one process can play both sides.

private func lockFile() throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-deep-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder, folder.appendingPathComponent("deep-transcription.lock"))
}

@Test func aPassIsRunningOnlyWhileItHoldsTheLock() throws {
    let (folder, url) = try lockFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(DeepTranscriptionLock.state(at: url) == .free, "No lock file: nothing ran yet.")
    let holder = DeepTranscriptionLock.Holder(pid: getpid(), sessionID: "S1", force: true)
    let taken = try #require(try DeepTranscriptionLock.take(holder, at: url, wait: .zero))
    #expect(DeepTranscriptionLock.state(at: url) == .held(holder), "Its pid and meeting are read while it holds it.")
    // A second pass does not start while one runs.
    #expect(try DeepTranscriptionLock.take(DeepTranscriptionLock.Holder(pid: getpid(), sessionID: "S2", force: false),
                                           at: url, wait: .zero) == nil)
    taken.release()
    // Released (as when its process ends, however it ends): free, whatever the file still says.
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(DeepTranscriptionLock.state(at: url) == .free)
    let next = try #require(try DeepTranscriptionLock.take(
        DeepTranscriptionLock.Holder(pid: getpid(), sessionID: "S2", force: false), at: url, wait: .zero))
    #expect(DeepTranscriptionLock.state(at: url) == .held(.init(pid: getpid(), sessionID: "S2", force: false)))
    next.release()
}

@Test func aHolderThatHasNotWrittenItselfYetIsRunningButUnknown() throws {
    let (folder, url) = try lockFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(DeepTranscriptionLock.state(at: url) == .held(nil))
    flock(fd, LOCK_UN)
    #expect(DeepTranscriptionLock.state(at: url) == .free)
}

@Test func onlyThePassHoldingTheLockIsSignalled() throws {
    let (folder, url) = try lockFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Signal 0 checks the process without signalling it.
    #expect(!DeepTranscriptionLock.signal("S1", 0, at: url), "Nothing holds it.")
    let taken = try #require(try DeepTranscriptionLock.take(
        DeepTranscriptionLock.Holder(pid: getpid(), sessionID: "S1", force: false), at: url, wait: .zero))
    #expect(DeepTranscriptionLock.signal("S1", 0, at: url))
    #expect(!DeepTranscriptionLock.signal("S2", 0, at: url), "Another meeting's pass.")
    taken.release()
    #expect(!DeepTranscriptionLock.signal("S1", 0, at: url), "Its pid may belong to another process once it ended.")
}
