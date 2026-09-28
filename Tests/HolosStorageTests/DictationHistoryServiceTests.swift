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
    #expect(!service.flush(timeout: 0.05))
    lock.release()
    // Once the lock is free, the flush returns only after the append reached the file.
    #expect(service.flush(timeout: 600))
    #expect(try fixture.store.load().records == [kept])

    service.delete(kept.id)
    #expect(service.flush(timeout: 600))
    #expect(try fixture.store.load().records.isEmpty)

    service.add(dictation("one"))
    service.add(dictation("two"))
    service.clear()
    #expect(service.flush(timeout: 600))
    #expect(try fixture.store.load().records.isEmpty, "A clear asked for before quitting is on disk.")
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
