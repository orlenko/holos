import Foundation
import HolosCore
import Synchronization
import Testing

@Suite struct TextTidierTests {
    private func tidier(partWords: Int = 100, timeout: Duration = .seconds(5),
                        _ reply: @escaping @Sendable (String) async throws -> String) -> TextTidier {
        TextTidier(partWords: partWords, timeout: timeout) { _, prompt in
            try await reply(String(prompt.dropFirst("Text:\n".count)))
        }
    }

    @Test func aShortTextIsOnePartAndTakesTheModelsEdit() async throws {
        let result = try await tidier { _ in "We should ship it on Friday, because the client is waiting." }
            .tidy("We should ship it. On Friday. Because the client. Is waiting.")
        #expect(result.text == "We should ship it on Friday, because the client is waiting.")
        #expect(result.parts.count == 1)
        #expect(result.parts[0].kept == nil)
    }

    @Test func eachPartIsSentAloneAndTheEditsJoinWithABlankLine() async throws {
        let seen = Mutex<[String]>([])
        let result = try await tidier(partWords: 4) { part in
            seen.withLock { $0.append(part) }
            return part.uppercased()
        }.tidy("one two three\n\nfour five six\n\nseven")
        #expect(seen.withLock { $0 } == ["one two three", "four five six\n\nseven"])
        #expect(result.text == "ONE TWO THREE\n\nFOUR FIVE SIX\n\nSEVEN")
    }

    @Test func aPartWhoseModelFailsKeepsItsOwnTextAndSaysWhy() async throws {
        struct Refused: Error {}
        let result = try await tidier(partWords: 3) { part in
            if part.hasPrefix("four") { throw Refused() }
            return part
        }.tidy("one two three\n\nfour five six")
        #expect(result.text == "one two three\n\nfour five six")
        #expect(result.parts.map(\.kept) == [nil, "the model gave no answer"])
    }

    @Test func aPartThatTakesTooLongKeepsItsOwnText() async throws {
        let result = try await tidier(timeout: .milliseconds(20)) { part in
            try await Task.sleep(for: .seconds(30))
            return part
        }.tidy("one two three")
        #expect(result.parts.map(\.kept) == ["the model took too long"])
        #expect(result.text == "one two three")
    }

    @Test func anEditThatDropsOrInventsTooMuchKeepsTheOriginal() async throws {
        let original = "I went to the store and bought milk eggs and bread for the whole week ahead of the trip"
        let summary = try await tidier { _ in "I went shopping." }.tidy(original)
        #expect(summary.parts[0].kept == "the model left out too many words")
        #expect(summary.text == original)
        let answer = try await tidier { part in part + " That sounds like a good plan, enjoy your trip and travel safe!" }
            .tidy(original)
        #expect(answer.parts[0].kept == "the model added words that were not said")
    }

    @Test func progressCountsPartsAndEndsWithAllDone() async throws {
        let seen = Mutex<[[Int]]>([])
        _ = try await tidier(partWords: 1) { $0 }.tidy("one two") { done, total in
            seen.withLock { $0.append([done, total]) }
        }
        #expect(seen.withLock { $0 } == [[0, 2], [1, 2], [2, 2]])
    }

    @Test func aCancelledTidyThrowsInsteadOfReturningPartOfTheText() async {
        let task = Task {
            try await tidier(partWords: 1) { part in
                try await Task.sleep(for: .milliseconds(10))
                return part
            }.tidy("one two three four five six seven eight")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func partsKeepParagraphsWholeAndSplitLongOnesAtSentenceEnds() {
        #expect(TextTidier.parts(of: "  \n\n ", maximumWords: 5).isEmpty)
        #expect(TextTidier.parts(of: "a b\n \nc d", maximumWords: 5) == ["a b\n\nc d"])
        #expect(TextTidier.parts(of: "One two. Three four! Five six?", maximumWords: 4)
            == ["One two. Three four!", "Five six?"])
        #expect(TextTidier.parts(of: "He said \"stop.\" Then left.", maximumWords: 3) == ["He said \"stop.\"", "Then left."])
        #expect(TextTidier.parts(of: "a b c d e f g", maximumWords: 3) == ["a b c", "d e f", "g"])
    }

    @Test func repliesLoseReasoningFencesLabelsAndIntroductions() {
        let original = "we should ship it"
        #expect(TextTidier.cleanedReply("<think>\nhmm\n</think>\n\nWe should ship it.", original: original)
            == "We should ship it.")
        #expect(TextTidier.cleanedReply("```\nWe should ship it.\n```", original: original) == "We should ship it.")
        #expect(TextTidier.cleanedReply("Text: We should ship it.", original: original) == "We should ship it.")
        #expect(TextTidier.cleanedReply("Here is the edited text:\n\nWe should ship it.", original: original)
            == "We should ship it.")
    }

    @Test func aFirstLineTheSpeakerSaidIsKeptEvenIfItLooksLikeAnIntroduction() {
        let original = "here is the text for the invitation: come at six"
        let reply = "Here is the text for the invitation:\nCome at six."
        #expect(TextTidier.cleanedReply(reply, original: original) == reply)
    }

    @Test func replyLinesBecomePlainText() {
        #expect(TextTidier.cleanedReply("Things:  \n*   milk\n• eggs\n  * bread", original: "")
            == "Things:\n- milk\n- eggs\n  - bread")
    }

    @Test func verdictAllowsDroppingFillersAndRejoiningSentences() {
        #expect(TextTidier.verdict(original: "Um. We should. Ship it. On Friday.",
                                   edited: "We should ship it on Friday.") == nil)
        #expect(TextTidier.verdict(original: "one two", edited: "  ") == "the model gave no text")
    }
}
