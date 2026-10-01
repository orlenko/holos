import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// `voiceislocal words add … --heard-as` and `voiceislocal words heard-as` as library calls (WordListCommand), on a
// words.json in a temporary folder.

private let heardAsCommandDate = Date(timeIntervalSince1970: 1_790_000_000)

private func heardAsStore() throws -> (WordListStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-heard-as-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (WordListStore(url: root.appendingPathComponent(WordListStore.fileName)), root)
}

@Test func addingATermWithItsHeardAsWords() throws {
    let (store, root) = try heardAsStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let added = try WordListCommand.add(["Claude"], heardAs: ["cloud", "clot", "clod"], store: store,
                                        at: heardAsCommandDate)
    #expect(added.exitCode == 0)
    #expect(added.output == ["Added: Claude.", "The word list has 1 term.",
                             "Claude is often heard as: cloud, clot, clod."])
    #expect(try store.load().heardAs(of: "claude") == ["cloud", "clot", "clod"])
    let text = try String(contentsOf: store.url, encoding: .utf8)
    #expect(text.contains("\"heardAs\" : ["))

    // Adding the term again adds to its words; one it has already is noted, the term itself refused.
    let again = try WordListCommand.add(["claude"], heardAs: ["clawed", "Cloud", "Claude"], store: store)
    #expect(again.exitCode == 1)
    #expect(again.errors.contains("Already in the word list: Claude"))
    #expect(again.errors.contains("Already listed for Claude: Cloud"))
    #expect(again.errors.contains { $0.hasPrefix("Not added for Claude: Claude") })
    #expect(again.output.last == "Claude is often heard as: cloud, clot, clod, clawed.")
}

@Test func changingAndListingHeardAsWords() throws {
    let (store, root) = try heardAsStore()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try WordListCommand.add(["Claude", "Keycloak"], store: store, at: heardAsCommandDate)

    let none = try WordListCommand.heardAs(of: nil, store: store)
    #expect(none.output.isEmpty && none.errors == ["No term has often-heard-as phrases."] && none.exitCode == 0)
    #expect(try WordListCommand.heardAs(of: "Claude", store: store).output == ["Claude has no often-heard-as phrases."])

    let changed = try WordListCommand.changeHeardAs(of: "CLAUDE", adding: ["cloud", "clot"], removing: ["clot"],
                                                    store: store)
    #expect(changed.exitCode == 0)
    #expect(changed.output == ["Claude is often heard as: cloud, clot.", "Removed: clot.",
                               "Claude is often heard as: cloud."])
    #expect(try WordListCommand.heardAs(of: nil, store: store).output == ["Claude: cloud"])
    #expect(try WordListCommand.heardAs(of: "claude", store: store).output == ["Claude: cloud"])

    let missing = try WordListCommand.changeHeardAs(of: "Codex", adding: ["codecs"], removing: [], store: store)
    #expect(missing.exitCode == 1 && missing.errors.first?.hasPrefix("Not in the word list: Codex") == true)
    let notListed = try WordListCommand.changeHeardAs(of: "Claude", adding: [], removing: ["clod"], store: store)
    #expect(notListed.exitCode == 1 && notListed.errors == ["Claude is not listed as heard as: clod"])
    #expect(try WordListCommand.heardAs(of: "Codex", store: store).exitCode == 1)

    // Removing a term removes its words with it.
    _ = try WordListCommand.remove(["Claude"], store: store)
    #expect(try store.load().heardAsPairs.isEmpty)
}
