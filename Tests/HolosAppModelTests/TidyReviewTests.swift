import HolosCore
@testable import HolosAppModel
import Testing

struct TidyReviewTests {
    func review(_ original: String, _ edited: String) -> TidyReview {
        TidyReview(text: edited, changes: WordChanges.between(original, edited))
    }

    @Test func removedWordsAppearStruckWhereTheyWereAndCopyLeavesThemOut() {
        let result = review("We went out. And then. We came back home.", "We went out and then came back home.")
        #expect(result.segments == [
            .init("We went out and then", .kept), .init(" We", .removed), .init(" came back home.", .kept),
        ])
        #expect(result.segments.filter { $0.kind != .removed }.map(\.text).joined() == result.text)
        #expect(result.removedWords == 1)
    }

    @Test func addedWordsAreMarked() {
        let result = review("So the plan is. We meet at noon.", "So the plan is to meet at noon.")
        #expect(result.segments.contains(.init("to", .added)))
        #expect(result.segments.contains { $0.kind == .removed && $0.text.contains("We") })
        #expect(result.segments.filter { $0.kind != .removed }.map(\.text).joined() == result.text)
    }

    @Test func aDroppedSentenceShowsWhole() {
        let original = "I called the bank. They said the card is on its way. Then I made dinner."
        let result = review(original, "I called the bank. Then I made dinner.")
        #expect(result.segments == [
            .init("I called the bank. ", .kept), .init("They said the card is on its way ", .removed),
            .init("Then I made dinner.", .kept),
        ])
        #expect(result.removedWords == 8)
    }

    @Test func punctuationAndCapitalsAloneAreNotChanges() {
        let result = review("we went out. and then came home", "We went out, and then came home.")
        #expect(result.segments == [.init("We went out, and then came home.", .kept)])
        #expect(result.summary.hasPrefix("No words changed"))
    }

    @Test func changesThatDoNotFitTheTextAreLeftOut() {
        let result = TidyReview(text: "short", changes: [.init(location: 3, length: 40, removed: "x")])
        #expect(result.segments == [.init("short", .kept)])
    }

    @Test func textWithEmojiKeepsItsUTF16Places() {
        let result = review("Hi 👋 um there", "Hi 👋 there")
        #expect(result.segments.filter { $0.kind != .removed }.map(\.text).joined() == "Hi 👋 there")
        #expect(result.segments.contains { $0.kind == .removed && $0.text.contains("um") })
    }
}
