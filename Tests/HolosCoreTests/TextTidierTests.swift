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

    @Test func eachPartIsSentAloneAndTheResultKeepsTheSpacingBetweenParts() async throws {
        let seen = Mutex<[String]>([])
        let result = try await tidier(partWords: 4) { part in
            seen.withLock { $0.append(part) }
            return part.uppercased()
        }.tidy("one two three\n\nfour five six\nseven")
        #expect(seen.withLock { $0 } == ["one two three", "four five six\nseven"])
        #expect(result.text == "ONE TWO THREE\n\nFOUR FIVE SIX\nSEVEN")
    }

    @Test func aPartWhoseModelFailsKeepsItsOwnTextAndSaysWhy() async throws {
        struct Refused: Error {}
        let result = try await tidier(partWords: 3) { part in
            if part.hasPrefix("four") { throw Refused() }
            return part
        }.tidy("one two three\n\nfour five six")
        #expect(result.text == "one two three\n\nfour five six")
        #expect(result.parts.map(\.kept) == [nil, "the model gave no answer"])
        #expect(!result.nothingTidied)
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
        #expect(summary.nothingTidied)
        let answer = try await tidier { part in part + " That sounds like a good plan, enjoy your trip and travel safe!" }
            .tidy(original)
        #expect(answer.parts[0].kept == "the model added words that were not said")
    }

    @Test func answersSummariesChatterAndDroppedPassagesFailTheVerdict() {
        #expect(TextTidier.verdict(original: "Can you send me the report?", edited: "Sure, I'll send you the report.")
            != nil)
        #expect(TextTidier.verdict(original: "I need milk today", edited: "Milk.") != nil)
        let hundred = (1 ... 100).map { "word\($0)" }.joined(separator: " ")
        #expect(TextTidier.verdict(original: hundred, edited: hundred + "\n\nLet me know if you would like changes!")
            == "the model added words that were not said")
        let words = (1 ... 600).map { "w\($0)" }
        let dropped = (words[..<200] + words[340...]).joined(separator: " ")
        #expect(TextTidier.verdict(original: words.joined(separator: " "), edited: dropped)
            == "the model left out too many words")
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

    @Test func partsKeepTheTextExactlyAndEndAtTheStrongestBreak() {
        #expect(TextTidier.parts(of: "  \n\n ", maximumWords: 5).isEmpty)
        #expect(TextTidier.parts(of: "a b\n \nc d", maximumWords: 5) == ["a b\n \nc d"])
        #expect(TextTidier.parts(of: "One two. Three four! Five six?", maximumWords: 4)
            == ["One two. Three four!", "Five six?"])
        #expect(TextTidier.parts(of: "He said \"stop.\" Then left.", maximumWords: 3) == ["He said \"stop.\"", "Then left."])
        #expect(TextTidier.parts(of: "a b c d e f g", maximumWords: 3) == ["a b c", "d e f", "g"])
        // A line break beats a sentence end, and a blank line beats both, after the first third of the words.
        #expect(TextTidier.parts(of: "a. b\nc d", maximumWords: 3) == ["a. b", "c d"])
        #expect(TextTidier.parts(of: "a b\n\nc. d e", maximumWords: 4) == ["a b", "c. d e"])
        #expect(TextTidier.parts(of: "a\n\nb c. d e", maximumWords: 4) == ["a\n\nb c.", "d e"])
    }

    @Test func piecesCarryTheSpacingAfterThemSoLinesSurvive() {
        let lines = (1 ... 80).map { "line \($0) has some more words in it today" }.joined(separator: "\n")
        let pieces = TextTidier.pieces(of: lines, maximumWords: 600)
        #expect(pieces.count == 2)
        #expect(pieces.map { $0.text + $0.separator }.joined() == lines)
        #expect(pieces[0].separator == "\n")
    }

    @Test func aShortFirstLineStaysWithTheTextAfterIt() {
        let prose = (1 ... 700).map { "w\($0)" }.joined(separator: " ")
        let parts = TextTidier.parts(of: "Dear John,\n" + prose, maximumWords: 600)
        #expect(parts.first?.hasPrefix("Dear John,\nw1 ") == true)
    }

    @Test func aTextWhosePartsAllFailComesBackExactly() async throws {
        struct Refused: Error {}
        let text = "  " + (1 ... 80).map { "- item \($0) is here today" }.joined(separator: "\n") + "\n\nThe end.\n\n"
        let result = try await tidier(partWords: 100) { _ in throw Refused() }.tidy(text)
        #expect(result.text == text)
        #expect(result.nothingTidied)
    }

    @Test func editsGetTheTextsOwnLineEnding() async throws {
        #expect(try await tidier { _ in "One.\nTwo." }.tidy("one\r\ntwo").text == "One.\r\nTwo.")
        #expect(try await tidier { _ in "One.\r\nTwo." }.tidy("one\r\ntwo").text == "One.\r\nTwo.")
        #expect(try await tidier { _ in "One.\r\nTwo." }.tidy("one\ntwo").text == "One.\nTwo.")
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

    @Test func aFirstLineWithAnyOfTheSpeakersWordsIsKept() {
        let tail = " " + (1 ... 60).map { "w\($0)" }.joined(separator: " ")
        let tailEdit = "\n" + (1 ... 60).map { "w\($0)" }.joined(separator: " ")
        for (said, wrote) in [("the new version has three changes", "The new version has 3 changes:"),
                              ("OK here are my notes", "Okay, here are my notes:"),
                              ("here's what happened", "Here is what happened:"),
                              ("the text of the knew law says", "The text of the new law says:"),
                              ("here is the text for the invitation", "Here is the text for the invitation:")] {
            #expect(TextTidier.cleanedReply(wrote + tailEdit, original: said + tail) == wrote + tailEdit)
        }
    }

    @Test func linesTheModelAddedAtTheStartOrEndAreDropped() {
        let part = (1 ... 50).map { "w\($0)" }.joined(separator: " ")
        for reply in ["Here it is:\n" + part, "Sure! Here's your revised journal entry:\n\n" + part,
                      "Voici le texte corrigé :\n" + part, "**Edited text:**\n" + part,
                      part + "\n\nHope this helps!", part + "\n\nAll done!\nLet me know."] {
            #expect(TextTidier.cleanedReply(reply, original: part) == part)
        }
    }

    @Test func aSentenceTheModelMovedToTheEndIsNotDropped() {
        let original = "Thanks for the draft. It looks great. See you at noon."
        let reply = "It looks great.\nThanks for the draft.\nSee you at noon."
        #expect(TextTidier.cleanedReply(reply, original: original) == reply)
    }

    @Test func aFirstOrLastLineTheModelRespelledOrMovedIsKept() {
        let body = "the report is attached and the numbers look right to me so please send it on to the client today"
        let cases: [(String, String)] = [
            ("hey, " + body + " cheers\nvlad", "Hi,\n\nThe report is attached and the numbers look right to me, so "
                + "please send it on to the client today.\n\nCheers,\nVlad"),
            (body + " thanks\njon", "The report is attached and the numbers look right to me, so please send it on to "
                + "the client today.\n\nThanks,\nJohn"),
            ("Oh and happy um birthday. " + body, "Happy birthday!\n\nThe report is attached and the numbers look "
                + "right to me, so please send it on to the client today."),
            ("Thanks uh for the draft. " + body, "The report is attached and the numbers look right to me, so please "
                + "send it on to the client today.\n\nThanks for the draft."),
            ("Thanks for the graft. " + body, "The report is attached and the numbers look right to me, so please send "
                + "it on to the client today.\n\nThanks for the draft."),
        ]
        for (original, reply) in cases {
            #expect(TextTidier.cleanedReply(reply, original: original) == reply)
        }
    }

    @Test func replyLineEndingsAreNormalizedBeforeCleaning() {
        #expect(TextTidier.cleanedReply("Things:  \r\n* milk", original: "things milk") == "Things:\n- milk")
    }

    @Test func replyLinesBecomePlainText() {
        #expect(TextTidier.cleanedReply("Things:  \n*   milk\n• eggs\n  * bread", original: "things milk eggs bread")
            == "Things:\n- milk\n- eggs\n  - bread")
    }

    @Test func aDroppedPassageOfRealProseFailsEvenThoughItsSmallWordsRepeat() {
        let filler = (1 ... 300).map { "w\($0)" }.joined(separator: " ")
        let passage = "The problem is that the vendor sent the invoice to the wrong address and the finance team paid "
            + "it twice, so now we have to ask the vendor to refund the second payment and the bank to reverse the "
            + "fee, and the auditors want a note on the whole thing by Friday."
        #expect(TextTidier.verdict(original: filler + " " + passage + " " + filler, edited: filler + " " + filler)
            == "the model left out too many words")
    }

    @Test func aRepeatIsExcusedOnlyWhileTheEditKeepsAnotherCopy() {
        let original = "we will not not go and then stay a while"
        #expect(TextTidier.verdict(original: original, edited: "we will not and then stay a while") == nil)
        #expect(TextTidier.verdict(original: original, edited: "we will and then stay a while")
            == "the model left out too many words")
    }

    @Test func verdictDoesNotCountFillersAndRepeatsAgainstTheEdit() {
        #expect(TextTidier.verdict(original: "Um so I I think we should uh we should go tomorrow",
                                   edited: "I think we should go tomorrow.") == nil)
    }

    @Test func verdictAllowsDroppingFillersAndRejoiningSentences() {
        #expect(TextTidier.verdict(original: "Um. We should. Ship it. On Friday.",
                                   edited: "We should ship it on Friday.") == nil)
        #expect(TextTidier.verdict(original: "one two", edited: "  ") == "the model gave no text")
    }
}
