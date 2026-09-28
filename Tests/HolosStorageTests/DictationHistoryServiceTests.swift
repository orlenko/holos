import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// DictationHistoryService (docs/design.md "Dictation history"): the app's in-memory history over the store, with its
// serial file queue flushed on quit and reloads that never drop a change made while they read.

@MainActor
private struct ServiceFixture {
    let root: URL
    let store: DictationHistoryStore
    let defaults: UserDefaults
    let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-history-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
        suite = "holos-history-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func service() -> DictationHistoryService {
        DictationHistoryService(store: store, defaults: defaults)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private func dictation(_ text: String) -> DictationRecord {
    // Whole seconds, as the file keeps dates, so a record read back equals the one written.
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    return DictationRecord(id: UUID(), date: now, app: "Notes", language: "en-CA", text: text, heard: text,
                           outcome: .init(kind: .inserted), seconds: 1)
}

/// Holds `dictations.lock` like another process writing the history, so the service's next write waits for it.
private final class HeldHistoryLock {
    private let fd: Int32

    init(_ store: DictationHistoryStore) throws {
        try AtomicFile.ensurePrivateDirectory(store.directory)
        fd = open(store.directory.appendingPathComponent(DictationHistoryStore.lockName).path,
                  O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else { throw HolosError.io("Cannot hold the history lock.") }
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

@MainActor
@Test func flushWaitsForQueuedWritesAndIsBounded() throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    let service = fixture.service()
    let kept = dictation("kept before quitting")

    let lock = try HeldHistoryLock(fixture.store)
    service.add(kept)
    // The append is stuck behind the lock: flushing gives up when its time runs out instead of hanging the quit.
    #expect(service.flush(timeout: 0.05) == .timedOut)
    lock.release()
    // Once the lock is free, the flush returns only after the append reached the file.
    #expect(service.flush(timeout: 600) == .written)
    #expect(try fixture.store.load().records == [kept])

    service.delete(kept.id)
    #expect(service.flush(timeout: 600) == .written)
    #expect(try fixture.store.load().records.isEmpty)

    service.add(dictation("one"))
    service.add(dictation("two"))
    service.clear()
    #expect(service.flush(timeout: 600) == .written)
    #expect(try fixture.store.load().records.isEmpty, "A clear asked for before quitting is on disk.")
}

/// Polls (a bounded number of turns, no clock) until `done` holds.
@MainActor
private func settle(_ done: () -> Bool) async {
    for _ in 0..<20_000 where !done() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
@Test func aFailedWriteIsReportedAndTheRecordsFollowTheFile() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    let service = fixture.service()
    var failures: [String] = []
    service.onFailure = { failures.append($0) }
    let kept = dictation("still on disk")
    service.add(kept)
    #expect(service.flush(timeout: 600) == .written)

    // The folder becomes read-only: the delete's atomic rewrite fails, and the dictation must not look deleted.
    #expect(chmod(fixture.store.directory.path, 0o500) == 0)
    defer { chmod(fixture.store.directory.path, 0o700) }
    service.delete(kept.id)
    #expect(service.records.isEmpty, "The delete shows at once…")
    #expect(service.flush(timeout: 600) == .failed, "…and a flush reports that a write failed.")
    await settle { !failures.isEmpty && service.records == [kept] }
    #expect(service.records == [kept], "…until the failure brings it back from the file.")
    #expect(failures.count == 1)
    #expect(service.problem?.hasPrefix("The dictation could not be deleted; it is still kept on this Mac.") == true)

    service.clear()
    await settle { failures.count == 2 && service.records == [kept] }
    #expect(service.records == [kept], "A failed Clear History leaves the kept dictations shown.")
    #expect(service.problem?.hasPrefix("History could not be cleared") == true)

    // The file itself becomes read-only: an append fails and the dictation is not shown as kept.
    #expect(chmod(fixture.store.directory.path, 0o700) == 0)
    #expect(chmod(fixture.store.fileURL.path, 0o400) == 0)
    let lost = dictation("not saved")
    service.add(lost)
    #expect(service.records == [kept, lost])
    await settle { failures.count == 3 && service.records == [kept] }
    #expect(service.records == [kept])
    #expect(service.problem?.hasPrefix("This dictation could not be saved in History.") == true)
    #expect(service.flush(timeout: 600) == .failed)
    #expect(service.flush(timeout: 600) == .written, "A flush reports each failure once.")

    // Once a later write succeeds, the warning clears (and the app's status message with it).
    #expect(chmod(fixture.store.fileURL.path, 0o600) == 0)
    var changes = 0
    service.onChange = { changes += 1 }
    service.add(dictation("saved again"))
    #expect(service.problem != nil, "Not before the write succeeded.")
    await settle { service.problem == nil }
    #expect(service.problem == nil)
    #expect(changes >= 2, "The add, then the recovery, are both reported.")
    #expect(service.flush(timeout: 600) == .written)
}

@MainActor
@Test func aNewerBuildsDictationsCountAsKeptAndClearDeletesThem() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    try AtomicFile.ensurePrivateDirectory(fixture.store.directory)
    try AtomicFile.append(Data("{\"schemaVersion\":9,\"text\":\"private words\"}\n".utf8), to: fixture.store.fileURL)
    let service = fixture.service()
    await service.reload().value
    #expect(service.records.isEmpty, "Not shown…")
    #expect(service.newerLines == 1)
    #expect(service.keptCount == 1, "…but counted, so Clear History and History Off's offer stay available.")

    service.clear()
    #expect(service.keptCount == 0)
    await service.flushed()
    await service.reload().value
    #expect(service.keptCount == 0)
    #expect(try Data(contentsOf: fixture.store.fileURL).isEmpty)
}

@MainActor
@Test func anUnreadableHistoryIsReportedNotShownAsEmpty() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    try fixture.store.append(dictation("private words"))
    #expect(chmod(fixture.store.fileURL.path, 0o000) == 0)
    defer { chmod(fixture.store.fileURL.path, 0o600) }
    let service = fixture.service()
    var failures: [String] = []
    service.onFailure = { failures.append($0) }

    let loading = service.reload()
    var unreadableWhenLoaded: Bool?
    service.whenLoaded { unreadableWhenLoaded = service.unreadable }
    await loading.value
    #expect(unreadableWhenLoaded == true, "The waiter runs, and learns the read failed rather than seeing no records.")
    #expect(service.unreadable)
    #expect(service.problem?.hasPrefix("History could not be read") == true)
    #expect(failures.count == 1)
    await service.reload().value
    #expect(failures.count == 1, "A failure already reported is not reported again on every reload.")

    // Clear History still works on the unreadable file, and the history reads again afterwards.
    service.clear()
    await service.flushed()
    await service.reload().value
    #expect(!service.unreadable)
    #expect(service.problem == nil)
    #expect(service.keptCount == 0)
}

@MainActor
@Test func whenLoadedWaitsForTheLaunchLoad() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    let earlier = [dictation("kept one"), dictation("kept two")]
    for record in earlier { try fixture.store.append(record) }
    let service = fixture.service()

    let loading = service.reload()
    var counted: Int?
    service.whenLoaded { counted = service.records.count }
    #expect(counted == nil, "Asked while the launch load reads: it waits.")
    await loading.value
    #expect(counted == 2, "It sees the dictations on disk, so History Off can offer to clear them.")

    var immediate: Int?
    service.whenLoaded { immediate = service.records.count }
    #expect(immediate == 2, "With no load reading, it runs at once.")
}

@MainActor
@Test func aReloadKeepsChangesMadeWhileItReads() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    let earlier = [dictation("earlier one"), dictation("earlier two")]
    for record in earlier { try fixture.store.append(record) }
    let service = fixture.service()

    // A dictation finishes while the launch load is still reading: the load is merged with it, not dropped.
    let reading = service.reload()
    let latest = dictation("finished during the load")
    service.add(latest)
    await reading.value
    #expect(service.records == earlier + [latest])

    // A delete and a clear made while a reload reads are applied to what it read too.
    let second = service.reload()
    service.delete(earlier[0].id)
    await second.value
    #expect(service.records == [earlier[1], latest])
    let third = service.reload()
    service.clear()
    await third.value
    #expect(service.records.isEmpty)
    await service.flushed()
    #expect(try fixture.store.load().records.isEmpty)
}

@MainActor
@Test func aReloadAfterTheCommandLineClearedShowsTheFile() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    let service = fixture.service()
    service.add(dictation("recorded"))
    await service.flushed()
    try fixture.store.clear()  // `voiceislocal history clear --yes`
    await service.reload().value
    #expect(service.records.isEmpty)
}

@MainActor
@Test func historyOffRecordsNothing() async throws {
    let fixture = try ServiceFixture()
    defer { fixture.remove() }
    let service = fixture.service()
    service.retention = .off
    service.add(dictation("not kept"))
    await service.flushed()
    #expect(service.records.isEmpty)
    #expect(try fixture.store.load().records.isEmpty)
}
