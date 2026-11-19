import Foundation
import HolosCore
import HolosDictation
import Testing

@Suite struct TidyCommandTests {
    @Test func theOutcomeCarriesTheEditAndTheWordsItChanged() async throws {
        let tidier = TextTidier(partWords: 100, timeout: .seconds(5)) { _, _ in "I went and ran home." }
        let outcome = try await TidyCommand.run("Um. I went. And. Ran home.", engine: .apple, tidier: tidier)
        #expect(outcome.engine == .apple)
        #expect(outcome.text == "I went and ran home.")
        #expect(outcome.changes == [WordChanges.Change(location: 0, length: 0, removed: "Um")])
        #expect(outcome.keptParts.isEmpty)
    }
}
