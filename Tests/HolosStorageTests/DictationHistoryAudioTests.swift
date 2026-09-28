import Darwin
import Foundation
import Synchronization
import Testing
import HolosCore
@testable import HolosStorage

// Dictation audio next to the history (docs/design.md "Dictation audio and Run Again"): kept with its record, and
// removed with it by Delete, Clear History, the retention sweep, and the audio setting.

private let audioNow = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

private func audioRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-history-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func dictation(_ text: String, date: Date = audioNow) -> DictationRecord {
    DictationRecord(id: UUID(), date: date, app: "Notes", language: "en-US", text: text, heard: text,
                    outcome: .init(kind: .inserted), seconds: 2)
}

/// Writes stand-in audio where a dictation's writer would, and returns it as finished.
private func partialAudio(for id: UUID, in store: DictationHistoryStore, seconds: Double = 2.5) throws
    -> DictationHistoryStore.FinishedAudio {
    try store.prepareAudioFolder()
    let url = store.partialAudioURL(for: id)
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: 1_000),
                                           attributes: [.posixPermissions: 0o600]))
    return .init(partial: url, seconds: seconds)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func mode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

private func age(_ url: URL, by seconds: TimeInterval) throws {
    let date = Date().addingTimeInterval(-seconds)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@Test func appendMovesTheAudioIntoPlaceAndLinksIt() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let record = dictation("With audio.")
    let finished = try partialAudio(for: record.id, in: store)
    let appended = try store.append(record, audio: finished)
    #expect(appended.audio == .init(file: "\(record.id.uuidString).m4a", seconds: 2.5))
    #expect(exists(store.audioURL(for: record.id)))
    #expect(!exists(finished.partial))
    #expect(mode(store.audioDirectory) == 0o700)
    #expect(mode(store.audioURL(for: record.id)) == 0o600)
    #expect(try store.load().records == [appended])
    #expect(store.audioBytes() == 1_000)

    // Audio that is not this dictation's partial file is not taken: the record is kept without it.
    let other = dictation("Mismatched.")
    let stray = try partialAudio(for: UUID(), in: store)
    let kept = try store.append(other, audio: stray)
    #expect(kept.audio == nil)
    #expect(!exists(stray.partial))
    // Nothing heard: no link either, and the partial goes.
    let silent = dictation("Silent.")
    let empty = try partialAudio(for: silent.id, in: store, seconds: 0)
    #expect(try store.append(silent, audio: empty).audio == nil)
    #expect(!exists(empty.partial))
}

@Test func deleteAndClearRemoveTheAudio() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let first = dictation("First.")
    let second = dictation("Second.")
    for record in [first, second] { _ = try store.append(record, audio: try partialAudio(for: record.id, in: store)) }
    #expect(try store.delete(id: first.id))
    #expect(!exists(store.audioURL(for: first.id)))
    #expect(exists(store.audioURL(for: second.id)))

    // A dictation in progress keeps its partial audio through Clear History; an old partial goes.
    let inProgress = try partialAudio(for: UUID(), in: store)
    let stale = try partialAudio(for: UUID(), in: store)
    try age(stale.partial, by: DictationHistoryStore.partialAudioLifetime + 60)
    #expect(try store.clear() == 1)
    #expect(!exists(store.audioURL(for: second.id)))
    #expect(exists(inProgress.partial))
    #expect(!exists(stale.partial))
    #expect(try store.load().records.isEmpty)
}

@Test func sweepRemovesSweptAudioOrphansAndStalePartialsButKeepsNewerLinesAudio() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let old = dictation("Old.", date: audioNow.addingTimeInterval(-40 * 86_400))
    let recent = dictation("Recent.")
    for record in [old, recent] { _ = try store.append(record, audio: try partialAudio(for: record.id, in: store)) }
    // A newer build's line with audio of its own.
    let newerID = UUID()
    let newerDate = ISO8601DateFormatter().string(from: audioNow)
    let newerLine = "{\"schemaVersion\":99,\"id\":\"\(newerID.uuidString)\",\"date\":\"\(newerDate)\"}\n"
    try AtomicFile.append(Data(newerLine.utf8), to: store.fileURL)
    _ = try partialAudio(for: newerID, in: store)
    #expect(rename(store.partialAudioURL(for: newerID).path, store.audioURL(for: newerID).path) == 0)
    // Audio whose record is gone (an older build rewrote the file), and partials old and new.
    let orphan = UUID()
    _ = try partialAudio(for: orphan, in: store)
    #expect(rename(store.partialAudioURL(for: orphan).path, store.audioURL(for: orphan).path) == 0)
    let stale = try partialAudio(for: UUID(), in: store)
    try age(stale.partial, by: 7_200)
    let fresh = try partialAudio(for: UUID(), in: store)
    // Something else in the folder is never touched.
    let other = store.audioDirectory.appendingPathComponent("notes.txt")
    #expect(FileManager.default.createFile(atPath: other.path, contents: Data("x".utf8)))

    #expect(try store.sweep(.days30, now: audioNow) == 1)
    #expect(!exists(store.audioURL(for: old.id)))
    #expect(exists(store.audioURL(for: recent.id)))
    #expect(exists(store.audioURL(for: newerID)))
    #expect(!exists(store.audioURL(for: orphan)))
    #expect(!exists(stale.partial))
    #expect(exists(fresh.partial))
    #expect(exists(other))

    // At launch no dictation is in progress: every partial goes.
    try store.sweep(before: .distantPast, partialsBefore: Date().addingTimeInterval(60))
    #expect(!exists(fresh.partial))
    #expect(exists(store.audioURL(for: recent.id)))
}

/// A store with a recent and an old dictation, each with audio, in a folder of its own.
private func storeWithAudio(_ root: URL, _ name: String) throws -> (DictationHistoryStore, [DictationRecord]) {
    let store = DictationHistoryStore(directory: root.appendingPathComponent(name).appendingPathComponent("History"))
    var records: [DictationRecord] = []
    for record in [dictation("Old.", date: audioNow.addingTimeInterval(-40 * 86_400)), dictation("Recent.")] {
        records.append(try store.append(record, audio: try partialAudio(for: record.id, in: store)))
    }
    return (store, records)
}

@Test func aRewriteThatFailsKeepsTheAudioItsRecordsLink() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let operations: [(String, (DictationHistoryStore, [DictationRecord]) throws -> Void)] = [
        ("delete", { store, records in try store.delete(id: records[0].id) }),
        ("clear", { store, _ in try store.clear() }),
        ("sweep", { store, _ in try store.sweep(.days30, now: audioNow) }),
        ("removeAllAudio", { store, _ in try store.removeAllAudio() }),
    ]
    for (name, operation) in operations {
        // A twin run finds the step that replaces the file; the real run fails there.
        let (twin, twinRecords) = try storeWithAudio(root, "twin-\(name)")
        let steps = FaultPlan()
        try AtomicFile.$faultPlan.withValue(steps) { try operation(twin, twinRecords) }
        let index = try #require(steps.steps.firstIndex(of: "rename dictations.jsonl"), "\(name): \(steps.steps)")

        let (store, records) = try storeWithAudio(root, name)
        #expect(throws: (any Error).self, "\(name)") {
            try AtomicFile.$faultPlan.withValue(FaultPlan(failAt: index)) { try operation(store, records) }
        }
        #expect(try store.load().records == records, "\(name): the file is as it was")
        for record in records {
            #expect(exists(store.audioURL(for: record.id)), "\(name): the audio is back")
        }
        #expect(store.audioFiles().allSatisfy { $0.kind == .finished }, "\(name): nothing left set aside")
    }
}

@Test func sweepPutsBackAudioACrashLeftAsideOnlyWhenItsRecordLinksIt() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, records) = try storeWithAudio(root, "crash")
    // A crash after the audio was set aside: one record still links it, the other's line was already gone.
    let linked = records[1]
    #expect(rename(store.audioURL(for: linked.id).path, store.audioURL(for: linked.id).path + ".removing") == 0)
    let gone = UUID()
    _ = try partialAudio(for: gone, in: store)
    #expect(rename(store.partialAudioURL(for: gone).path, store.audioURL(for: gone).path + ".removing") == 0)
    try store.sweep(before: .distantPast)
    #expect(exists(store.audioURL(for: linked.id)))
    #expect(!exists(URL(fileURLWithPath: store.audioURL(for: gone).path + ".removing")))
    #expect(store.audioFiles().allSatisfy { $0.kind == .finished })
}

@Test func sweepDropsAudioALineNoLongerLinks() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, records) = try storeWithAudio(root, "unlinked")
    // An older build rewrote the file and dropped the (to it unknown) audio link of the recent record.
    var unlinked = records[1]
    unlinked.audio = nil
    try AtomicFile.write(try HolosJSON.line(records[0]) + HolosJSON.line(unlinked), to: store.fileURL)
    try store.sweep(before: .distantPast)
    #expect(!exists(store.audioURL(for: unlinked.id)), "Nothing can play it any more.")
    #expect(exists(store.audioURL(for: records[0].id)))
    #expect(try store.load().records.map(\.text) == ["Old.", "Recent."])
}

@Test func removingAllAudioDropsFilesAndLinksButKeepsTheText() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let record = dictation("Kept text.")
    let plain = dictation("No audio.")
    _ = try store.append(record, audio: try partialAudio(for: record.id, in: store))
    try store.append(plain)
    #expect(try store.removeAllAudio() == 1)
    #expect(!exists(store.audioURL(for: record.id)))
    #expect(try store.load().records.map(\.text) == ["Kept text.", "No audio."])
    #expect(try store.load().records.allSatisfy { $0.audio == nil })
    #expect(store.audioBytes() == 0)
}

@Test func updateReplacesTheTextAndKeepsTheAudio() throws {
    let root = try audioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let original = dictation("I use a boon to.")
    let record = try store.append(original, audio: try partialAudio(for: original.id, in: store))
    try store.append(dictation("Another."))
    var changed = record
    changed.text = "I use Ubuntu."
    #expect(try store.update(changed))
    #expect(try store.load().records.map(\.text) == ["I use Ubuntu.", "Another."])
    #expect(try store.load().records.first?.audio == record.audio)
    #expect(exists(store.audioURL(for: record.id)))
    #expect(try !store.update(dictation("Gone.")))
}

/// Stand-in for a dictation's audio writer.
private final class FakeRecording: DictationAudioRecording, Sendable {
    let finished: DictationHistoryStore.FinishedAudio?
    private let calls = Mutex<[String]>([])

    init(_ finished: DictationHistoryStore.FinishedAudio?) { self.finished = finished }

    var log: [String] { calls.withLock { $0 } }

    func finish() -> DictationHistoryStore.FinishedAudio? {
        calls.withLock { $0.append("finish") }
        return finished
    }

    func discard() {
        calls.withLock { $0.append("discard") }
        if let finished { try? DictationHistoryStore.removeAudioFile(finished.partial) }
    }
}

@MainActor
@Test func serviceLinksAudioOnceWrittenAndDropsItWhenNotKept() async throws {
    let root = try audioRoot()
    let suite = "holos-history-audio-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let service = DictationHistoryService(store: store, defaults: defaults)
    #expect(service.keepsAudio)
    #expect(service.recordsAudio)

    let record = dictation("With audio.")
    let recording = FakeRecording(try partialAudio(for: record.id, in: store))
    service.add(record, audio: recording)
    #expect(service.records.first?.audio == nil, "Linked once the file is in place.")
    await service.flushed()
    try await pollUntil { service.records.first?.audio != nil }
    #expect(recording.log == ["finish"])
    #expect(service.records.first?.audio?.seconds == 2.5)
    #expect(service.audioBytes == 1_000)
    #expect(try store.load().records.first?.audio != nil)

    // The audio setting off: the audio is deleted and the text kept.
    service.keepsAudio = false
    #expect(!service.recordsAudio)
    let quiet = dictation("Text only.")
    let dropped = FakeRecording(try partialAudio(for: quiet.id, in: store))
    service.add(quiet, audio: dropped)
    await service.flushed()
    #expect(dropped.log == ["discard"])
    #expect(!exists(store.partialAudioURL(for: quiet.id)))
    #expect(try store.load().records.map(\.text) == ["With audio.", "Text only."])

    // History off: nothing is recorded, the audio neither.
    service.keepsAudio = true
    service.retention = .off
    #expect(!service.recordsAudio)
    let off = dictation("Not kept.")
    let unkept = FakeRecording(try partialAudio(for: off.id, in: store))
    service.add(off, audio: unkept)
    await service.flushed()
    #expect(unkept.log == ["discard"])
    #expect(try store.load().records.count == 2)

    // Deleting all audio clears the links in memory and on disk.
    service.retention = .days30
    service.removeAllAudio()
    #expect(service.records.allSatisfy { $0.audio == nil })
    await service.flushed()
    try await pollUntil { service.audioBytes == 0 }
    #expect(!exists(store.audioURL(for: record.id)))
    #expect(try store.load().records.allSatisfy { $0.audio == nil })

    // Delete removes a dictation's audio.
    let spoken = dictation("Spoken.")
    service.add(spoken, audio: FakeRecording(try partialAudio(for: spoken.id, in: store)))
    await service.flushed()
    try await pollUntil { service.records.last?.audio != nil }
    service.delete(spoken.id)
    await service.flushed()
    #expect(!exists(store.audioURL(for: spoken.id)))
}

@MainActor
@Test func anAudioLinkLandingLateNeverUndoesLaterChanges() async throws {
    let root = try audioRoot()
    let suite = "holos-history-audio-order-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let service = DictationHistoryService(store: store, defaults: defaults)

    // Deleting all audio right after a dictation was added: its link, landing after, must not come back.
    let first = dictation("First.")
    service.add(first, audio: FakeRecording(try partialAudio(for: first.id, in: store)))
    service.removeAllAudio()
    await service.flushed()
    try await pollUntil { service.audioBytes == 0 }
    #expect(service.records.allSatisfy { $0.audio == nil })
    #expect(try store.load().records.allSatisfy { $0.audio == nil })

    // Update History made before the link landed keeps its text, and the link still lands.
    let second = dictation("I use a boon to.")
    service.add(second, audio: FakeRecording(try partialAudio(for: second.id, in: store)))
    var updated = second
    updated.text = "I use Ubuntu."
    service.update(updated)
    await service.flushed()
    try await pollUntil { service.records.last?.audio != nil }
    #expect(service.records.last?.text == "I use Ubuntu.")
    #expect(try store.load().records.last?.text == "I use Ubuntu.")
    #expect(try store.load().records.last?.audio != nil, "Update History never drops the audio link on disk.")
}

@MainActor
@Test func anUpdateOfADictationClearedElsewhereLeavesItCleared() async throws {
    let root = try audioRoot()
    let suite = "holos-history-audio-update-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let service = DictationHistoryService(store: store, defaults: defaults)
    let record = dictation("Kept.")
    service.add(record)
    await service.flushed()
    // `voiceislocal history clear --yes` in Terminal, before the app's update reaches the file.
    try store.clear()
    var updated = record
    updated.text = "Changed."
    service.update(updated)
    await service.flushed()
    try await pollUntil { service.records.isEmpty }
    #expect(try store.load().records.isEmpty)
}

/// Waits for main-actor work the service posted after its queue finished, by polling a bounded number of times.
@MainActor
private func pollUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "The condition never held.")
}
