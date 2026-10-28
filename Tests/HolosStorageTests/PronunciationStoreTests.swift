import Foundation
import Testing
import HolosCore
@testable import HolosStorage
import HolosTestSupport

// pronunciations.json (docs/design.md "Pronunciations"): versioned, written whole and atomically (0600), changed under
// a lock; and `voiceislocal pronunciations` as library calls (PronunciationCommand).

private let day = Date(timeIntervalSince1970: 1_790_000_000)

private func store() throws -> PronunciationStore {
    let root = try TemporaryDirectory("pronunciations").url
    return PronunciationStore(url: root.appendingPathComponent(PronunciationStore.fileName))
}

@Test func aMissingPronunciationListLoadsEmptyAndCreatesNothing() throws {
    let store = try store()
    #expect(try store.load() == PronunciationList())
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
}

@Test func thePronunciationListIsSavedPrivatelyAndVersioned() throws {
    let store = try store()
    let (list, _) = try store.update { $0.set("XIMEA", sayAs: "zai mee ah", at: day) }
    #expect(try store.load() == list)
    #expect(FileInspection.mode(store.url) == 0o600)
    let text = try String(contentsOf: store.url, encoding: .utf8)
    #expect(text.contains("\"schemaVersion\" : 1") && text.contains("\"sayAs\" : \"zai mee ah\""))
    let names = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
    #expect(Set(names) == [PronunciationStore.fileName, PronunciationStore.lockName])
}

@Test func aNewerOrDamagedListIsRefusedAndNeverOverwritten() throws {
    let store = try store()
    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let newer = #"{"schemaVersion": 2, "entries": [], "future": true}"#
    try Data(newer.utf8).write(to: store.url)
    #expect(throws: HolosError.self) { try store.load() }
    #expect(throws: HolosError.self) { try store.update { $0.set("a", sayAs: "b") } }
    #expect(try String(contentsOf: store.url, encoding: .utf8) == newer)
    // Two entries written alike, or a spelling with stray spaces, is damage, not half a list.
    for entries in [#"[{"written":"a","sayAs":"b","addedAt":"2026-10-28T00:00:00Z"},"#
                        + #"{"written":"a","sayAs":"c","addedAt":"2026-10-28T00:00:00Z"}]"#,
                    #"[{"written":"a","sayAs":" b","addedAt":"2026-10-28T00:00:00Z"}]"#] {
        try Data(#"{"schemaVersion": 1, "entries": \#(entries)}"#.utf8).write(to: store.url)
        #expect(throws: HolosError.self) { try store.load() }
    }
}

@Test func theCommandSetsChangesListsAndRemoves() throws {
    let store = try store()
    #expect(try PronunciationCommand.set("XIMEA", sayAs: "zai mee ah", store: store, at: day).output
        == ["Added: XIMEA → zai mee ah.", "The pronunciation list has 1 entry."])
    let changed = try PronunciationCommand.set("XIMEA", sayAs: "zee mee ah", store: store)
    #expect(changed.output.first == "Changed: XIMEA → zee mee ah (was zai mee ah).")
    let same = try PronunciationCommand.set("XIMEA", sayAs: "zee mee ah", store: store)
    #expect(same.errors == ["Already listed: XIMEA → zee mee ah."] && same.exitCode == 0)
    #expect(try PronunciationCommand.list(store: store) == ["XIMEA → zee mee ah"])
    let removed = try PronunciationCommand.remove(["XIMEA", "ximea"], store: store)
    #expect(removed.output == ["Removed: XIMEA.", "The pronunciation list has 0 entries."])
    #expect(removed.errors == ["Not in the pronunciation list: ximea"] && removed.exitCode == 1)
}
