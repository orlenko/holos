import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// words.json (docs/design.md "Word list"): versioned, written whole and atomically (0600), changed under a lock on
// the list as it is on disk; and `voiceislocal words` as library calls (WordListCommand).

private let wordsDate = Date(timeIntervalSince1970: 1_790_000_000)

private func wordsStore() throws -> WordListStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-words-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return WordListStore(url: root.appendingPathComponent(WordListStore.fileName))
}

private func mode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

@Test func aMissingWordListLoadsEmptyAndCreatesNothing() throws {
    let store = try wordsStore()
    #expect(try store.load() == WordList())
    #expect(store.stamp() == nil)
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
}

@Test func theWordListIsSavedPrivatelyAndVersioned() throws {
    let store = try wordsStore()
    let (list, outcome) = try store.update { $0.add("Keycloak", at: wordsDate) }
    #expect(outcome == .added("Keycloak") && list.terms == ["Keycloak"])
    #expect(mode(store.url) == 0o600)
    let text = try String(contentsOf: store.url, encoding: .utf8)
    #expect(text.contains("\"schemaVersion\" : 1") && text.contains("\"source\" : \"user\"")
        && text.contains("\"addedAt\" : \"2026-09-2"))
    #expect(try store.load().terms == ["Keycloak"])
    // No temporary file is left next to it.
    let names = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
    #expect(Set(names) == [WordListStore.fileName, WordListStore.lockName])
}

@Test func anUnchangedListIsNotRewritten() throws {
    let store = try wordsStore()
    try store.update { $0.add("Apex", at: wordsDate) }
    let before = store.stamp()
    #expect(before != nil)
    let (_, outcome) = try store.update { $0.add("apex") }
    #expect(outcome == .duplicate(existing: "Apex"))
    #expect(store.stamp() == before)
}

@Test func eachChangeStartsFromTheListOnDisk() throws {
    let store = try wordsStore()
    let other = WordListStore(url: store.url)
    try store.update { $0.add("Davin", at: wordsDate) }
    // Another process (the CLI) adds a term; this one's next change keeps it.
    try other.update { $0.add("Geofence", at: wordsDate) }
    let (list, _) = try store.update { $0.add("Fab", at: wordsDate) }
    #expect(list.terms == ["Davin", "Geofence", "Fab"])
    #expect(try other.load().terms == ["Davin", "Geofence", "Fab"])
}

@Test func aDamagedOrNewerWordListIsRefusedAndKept() throws {
    let store = try wordsStore()
    for contents in ["not json", #"{"schemaVersion": 2, "entries": []}"#] {
        try Data(contents.utf8).write(to: store.url)
        #expect(throws: HolosError.self) { try store.load() }
        #expect(throws: HolosError.self) { try store.update { $0.add("Apex") } }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == contents)
    }
}

@Test func theStampChangesWhenTheListIsWritten() throws {
    let store = try wordsStore()
    try store.update { $0.add("ops", at: wordsDate) }
    let first = store.stamp()
    try store.update { $0.add("AtmoSys", at: wordsDate) }
    #expect(store.stamp() != first)
}

@Test func theWordsCommandAddsRemovesAndImports() throws {
    let store = try wordsStore()
    let added = try WordListCommand.add(["Volpe lite", "Husky bus", "Davin", "davin", " "], store: store, at: wordsDate)
    #expect(added.output == ["Added: Volpe lite, Husky bus, Davin.", "The word list has 3 terms."])
    #expect(added.errors == ["Already in the word list: Davin"] && added.exitCode == 0)
    #expect(try WordListCommand.list(store: store) == ["Volpe lite", "Husky bus", "Davin"])

    let long = try WordListCommand.add([String(repeating: "x", count: 101)], store: store)
    #expect(long.exitCode == 1 && long.errors.count == 1)

    let removed = try WordListCommand.remove(["HUSKY BUS", "Keycloak"], store: store)
    #expect(removed.output == ["Removed: Husky bus.", "The word list has 2 terms."])
    #expect(removed.errors == ["Not in the word list: Keycloak"] && removed.exitCode == 1)

    let file = store.url.deletingLastPathComponent().appendingPathComponent("terms.txt")
    try Data("Geofence\n\nApex\r\nUrban Sky\nvolpe LITE\n".utf8).write(to: file)
    let imported = try WordListCommand.importFile(file, store: store, at: wordsDate)
    #expect(imported.output == ["Added: Geofence, Apex, Urban Sky.", "The word list has 5 terms."])
    #expect(imported.errors == ["Already in the word list: Volpe lite"])
    #expect(try store.load().terms == ["Volpe lite", "Davin", "Geofence", "Apex", "Urban Sky"])
}

@Test func theWordsCommandRefusesFilesItCannotRead() throws {
    let store = try wordsStore()
    let folder = store.url.deletingLastPathComponent()
    #expect(throws: HolosError.self) { try WordListCommand.terms(inFile: folder.appendingPathComponent("missing.txt")) }
    let binary = folder.appendingPathComponent("binary.txt")
    try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
    #expect(throws: HolosError.self) { try WordListCommand.terms(inFile: binary) }
    let large = folder.appendingPathComponent("large.txt")
    try Data(repeating: 0x61, count: WordListCommand.maxImportBytes + 1).write(to: large)
    #expect(throws: HolosError.self) { try WordListCommand.terms(inFile: large) }
    #expect(try store.load().isEmpty)
}

@Test func theCountSaysWhenTheRecognizerGetsOnlyPartOfTheList() {
    #expect(WordListCommand.countLine(1) == "The word list has 1 term.")
    #expect(WordListCommand.countLine(101) == "The word list has 101 terms; the recognizer gets the first 100.")
}
