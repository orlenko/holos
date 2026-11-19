import Foundation
import HolosCore
import Testing

@Suite struct WordChangesTests {
    /// The edit's text at a change, and what it removed.
    private func marked(_ original: String, _ edited: String) -> [[String]] {
        let utf16 = Array(edited.utf16)
        return WordChanges.between(original, edited).map { change in
            [String(decoding: utf16[change.location ..< change.location + change.length], as: UTF16.self),
             change.removed]
        }
    }

    @Test func punctuationCapitalsAndLineBreaksAreNotChanges() {
        #expect(WordChanges.between("We should. Ship it. On Friday.", "We should ship it\non Friday!").isEmpty)
        #expect(WordChanges.between("don’t stop", "Don't stop.").isEmpty)
    }

    @Test func removedWordsAreReportedWhereTheyWere() {
        let changes = WordChanges.between("Um. I went. And. Ran home.", "I went and ran home.")
        #expect(changes == [WordChanges.Change(location: 0, length: 0, removed: "Um")])
        #expect(marked("I went. And so. Ran home.", "I went and ran home.") == [["", "so"]])
    }

    @Test func addedAndReplacedWordsAreMarkedInTheEdit() {
        #expect(marked("any arbitrator blurb of text", "any arbitrary blurb of text") == [["arbitrary", "arbitrator"]])
        #expect(marked("call mom", "call my mom") == [["my", ""]])
        #expect(marked("a b c d", "a x y d") == [["x y", "b c"]])
    }

    @Test func offsetsCountUTF16SoTheyFitNSRange() {
        let edited = "🙂 Café is open"
        let changes = WordChanges.between("🙂 Café was open", edited)
        #expect(changes.count == 1)
        #expect((edited as NSString).substring(with: NSRange(location: changes[0].location, length: changes[0].length))
            == "is")
    }

    @Test func wordsKeepInnerApostrophesAndCompareLowercased() {
        #expect(WordChanges.words(in: "L’heure, don't 'quoted'").map(\.word) == ["l'heure", "don't", "quoted"])
    }
}
