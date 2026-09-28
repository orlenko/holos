import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// DictationHistoryStore (docs/design.md "Dictation history"): append-only JSON lines, private files, atomic
// rewrites for delete, clear, and the retention sweep.

private let storeNow = Date(timeIntervalSince1970: 1_790_000_000)

private func historyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func historyMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

private func entry(_ text: String, date: Date = storeNow) -> DictationRecord {
    DictationRecord(id: UUID(), date: date, app: "Notes", language: "fr-CA", text: text, heard: text,
                    outcome: .init(kind: .inserted), seconds: 2)
}

@Test func missingHistoryLoadsEmptyAndCreatesNothing() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    #expect(try store.load() == .init(records: [], skippedLines: 0))
    #expect(try store.clear() == 0)
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func appendKeepsOrderAndFilesArePrivate() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let first = entry("premier"), second = entry("second")
    try store.append(first)
    try store.append(second)
    #expect(try store.load().records == [first, second])
    #expect(historyMode(store.fileURL) == 0o600)
    #expect(historyMode(store.directory) == 0o700)
    let text = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(text.split(separator: "\n").count == 2, "One JSON line per dictation.")
}

@Test func deleteAndClearRewriteTheFile() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let first = entry("one"), second = entry("two"), third = entry("three")
    for record in [first, second, third] { try store.append(record) }
    #expect(try store.delete(id: second.id))
    #expect(try !store.delete(id: second.id), "Already gone.")
    #expect(try store.load().records == [first, third])
    #expect(historyMode(store.fileURL) == 0o600)
    #expect(try store.clear() == 2)
    #expect(try store.load().records.isEmpty)
    let data = try Data(contentsOf: store.fileURL)
    #expect(data.isEmpty, "Clearing leaves no text behind in the file.")
}

@Test func sweepRemovesOldRecordsAndUnreadableLines() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let old = entry("old", date: storeNow.addingTimeInterval(-40 * 86_400))
    let week = entry("week", date: storeNow.addingTimeInterval(-8 * 86_400))
    let recent = entry("recent", date: storeNow.addingTimeInterval(-3600))
    for record in [old, week, recent] { try store.append(record) }
    try AtomicFile.append(Data("not json\n".utf8), to: store.fileURL)
    #expect(try store.load().skippedLines == 1)

    #expect(try store.sweep(.off, now: storeNow) == 0)
    #expect(try store.load().records.count == 3)
    #expect(try store.sweep(.forever, now: storeNow) == 0)
    let forever = try store.load()
    #expect(forever.records == [old, week, recent], "Forever keeps every record…")
    #expect(forever.skippedLines == 0, "…but its sweep still compacts damaged lines away.")

    try AtomicFile.append(Data("damaged again\n".utf8), to: store.fileURL)
    #expect(try store.sweep(.days30, now: storeNow) == 1)
    let afterMonth = try store.load()
    #expect(afterMonth.records == [week, recent])
    #expect(afterMonth.skippedLines == 0, "The sweep compacts damaged lines away.")

    #expect(try store.sweep(.days7, now: storeNow) == 1)
    #expect(try store.load().records == [recent])
}

@Test func appendAfterClearStartsAgain() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    try store.append(entry("before"))
    try store.clear()
    let after = entry("after")
    try store.append(after)
    #expect(try store.load().records == [after])
}

@Test func loadStreamsLinesAcrossReadsAndSkipsOnlyOversizedOnes() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let records = (0..<12).map { entry("dictation number \($0)") }
    for record in records { try store.append(record) }
    let lineBytes = try HolosJSON.line(records[0]).count
    // A huge line (as if damaged, or from a much larger dictation) in the middle, and a torn last line.
    try AtomicFile.append(Data(String(repeating: "x", count: lineBytes * 3).utf8) + Data("\n".utf8),
                          to: store.fileURL)
    let after = entry("after the long line")
    try store.append(after)
    try AtomicFile.append(Data("{\"schemaVersion\":1,\"id\"".utf8), to: store.fileURL)

    // Reads far smaller than a line, and a line cap below the huge line: every record still loads.
    store.readChunkBytes = 7
    store.maxLineBytes = lineBytes * 2
    let streamed = try store.load()
    #expect(streamed.records == records + [after])
    #expect(streamed.skippedLines == 2, "The oversized line and the torn tail, nothing else.")

    // No size makes the whole file unreadable; the sweep compacts the skipped lines away.
    store.readChunkBytes = 1 << 20
    #expect(try store.sweep(.forever) == 0)
    let compacted = try store.load()
    #expect(compacted.records == records + [after])
    #expect(compacted.skippedLines == 0)
}

@Test func loadRefusesASymbolicLinkInPlaceOfTheFile() throws {
    let root = try historyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    try AtomicFile.ensurePrivateDirectory(store.directory)
    let elsewhere = root.appendingPathComponent("elsewhere.jsonl")
    try Data().write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: elsewhere)
    #expect(throws: HolosError.self) { try store.load() }
}
