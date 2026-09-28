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
