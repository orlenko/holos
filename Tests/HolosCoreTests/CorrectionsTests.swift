import Foundation
import Testing
@testable import HolosCore

@Test func appliesWholeWordCaseInsensitiveCorrections() {
    let list = CorrectionList(entries: [.init(heard: "bull request", meant: "pull request"),
                                        .init(heard: "Holus", meant: "Holos")])
    #expect(list.apply(to: "Open a bull request for holus.") == "Open a pull request for Holos.")
    #expect(list.apply(to: "Bull  request merged") == "Pull request merged")
    #expect(list.apply(to: "a bull market; Holusville") == "a bull market; Holusville")
}

@Test func streamingWithholdsAPossiblePhraseStart() {
    let list = CorrectionList(entries: [.init(heard: "bull request", meant: "pull request")])
    #expect(list.applyWithholdingPartialMatch(to: "Open a bull") == "Open a")
    #expect(list.applyWithholdingPartialMatch(to: "Open a bull request") == "Open a pull request")
    #expect(list.applyWithholdingPartialMatch(to: "Open a door") == "Open a door")
    let full = list.apply(to: "Open a bull market")
    #expect(full.hasPrefix(list.applyWithholdingPartialMatch(to: "Open a bull")))
}

@Test func learnsSubstitutionsWithContextForDictionaryWords() {
    let dictionary: Set<String> = ["bull", "open", "a", "request"]
    let learned = CorrectionList.learn(original: "Open a bull request for Holus.",
                                       corrected: "Open a pull request for Holos.",
                                       isDictionaryWord: { dictionary.contains($0.lowercased()) })
    #expect(learned == [.init(heard: "bull request", meant: "pull request"),
                        .init(heard: "Holus", meant: "Holos")])
}

@Test func ignoresInsertionsDeletionsAndRewrites() {
    #expect(CorrectionList.learn(original: "send it now", corrected: "send it right now").isEmpty)
    #expect(CorrectionList.learn(original: "send it right now", corrected: "send it now").isEmpty)
    #expect(CorrectionList.learn(original: "one two three four five six seven",
                                 corrected: "alpha beta gamma delta epsilon zeta eta").isEmpty)
    #expect(CorrectionList.learn(original: "done.", corrected: "done!").isEmpty)
}

@Test func addingReplacesTheSameHeardPhraseAndRoundTrips() throws {
    var list = CorrectionList()
    list.add(.init(heard: "clod", meant: "cloud"))
    list.add(.init(heard: "Clod ", meant: "Claude"))
    list.add(.init(heard: "same", meant: "same"))
    #expect(list.entries == [.init(heard: "Clod", meant: "Claude")])
    #expect(list.vocabulary == ["Claude"])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("corrections.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try list.save(to: url)
    #expect(try CorrectionList.load(from: url) == list)
    #expect(try CorrectionList.load(from: url.appendingPathExtension("missing")) == CorrectionList())
}

@Test func reviewFindingsOnMatchingAndStreaming() {
    let overlapping = CorrectionList(entries: [.init(heard: "foo", meant: "bar"), .init(heard: "foo baz", meant: "qux")])
    let streamed = overlapping.applyWithholdingPartialMatch(to: "say foo")
    #expect(streamed == "say")
    #expect(overlapping.apply(to: "say foo baz").hasPrefix(streamed))
    #expect(overlapping.apply(to: "say foo baz") == "say qux")

    let apostrophes = CorrectionList(entries: [.init(heard: "can", meant: "Ken")])
    #expect(apostrophes.apply(to: "I can't, you can’t, but can") == "I can't, you can’t, but Ken")

    let casing = CorrectionList(entries: [.init(heard: "Mac OS", meant: "macOS"), .init(heard: "Apple", meant: "apple"),
                                          .init(heard: "bull request", meant: "pull request")])
    #expect(casing.apply(to: "Mac OS and Apple") == "macOS and apple")
    #expect(casing.apply(to: "Bull request") == "Pull request")
}

@Test func declinesDictionaryWordRulesWithoutContext() {
    #expect(CorrectionList.learn(original: "Bull.", corrected: "Pull.", isDictionaryWord: { _ in true }).isEmpty)
    #expect(CorrectionList.learn(original: "Holus.", corrected: "Holos.", isDictionaryWord: { _ in false })
        == [.init(heard: "Holus", meant: "Holos")])
}

@Test func reportsDictionaryWordSwapsItDeclines() {
    let text = "Hi, Gwen. Good morning."
    let fixed = "Hi, Gwyn. Good morning."
    let everyWordIsCommon = CorrectionList.learnReportingDeclined(original: text, corrected: fixed) { _ in true }
    #expect(everyWordIsCommon.learned.isEmpty)
    #expect(everyWordIsCommon.declined == [.init(heard: "Gwen", meant: "Gwyn")])
    // A name whose lowercase form is not a word is learned on its own.
    let namesAreNotCommon = CorrectionList.learnReportingDeclined(original: text, corrected: fixed) { $0 != "Gwen" }
    #expect(namesAreNotCommon.learned == [.init(heard: "Gwen", meant: "Gwyn")])
    #expect(namesAreNotCommon.declined.isEmpty)
}

@Test func declinedMeantTextKeepsTheCorrectedPunctuation() {
    let result = CorrectionList.learnReportingDeclined(original: "Bull.", corrected: "Pull-request.") { _ in true }
    #expect(result.learned.isEmpty)
    #expect(result.declined == [.init(heard: "Bull", meant: "Pull-request")])
}

@Test func declinedQueueKeepsEveryPairUntilAddedOrSkipped() {
    var queue = DeclinedCorrectionQueue()
    queue.receive([.init(heard: "Bull", meant: "Pull"), .init(heard: "Male", meant: "Mail")])
    // A later Learn adds behind the waiting pairs; a repeated phrase is replaced in place.
    queue.receive([.init(heard: "bull", meant: "Poll"), .init(heard: "Tail", meant: "Tale")])
    #expect(queue.pending == [.init(heard: "bull", meant: "Poll"), .init(heard: "Male", meant: "Mail"),
                              .init(heard: "Tail", meant: "Tale")])

    // Pre-fill only when both fields are blank, so a half-typed manual correction survives.
    #expect(queue.prefill(heard: "", meant: " ") == .init(heard: "bull", meant: "Poll"))
    #expect(queue.prefill(heard: "clod", meant: "") == nil)
    #expect(queue.prefill(heard: "", meant: "cloud") == nil)

    // Adding any rule for a waiting phrase resolves it, even with an edited meant text.
    let resolvedEdited = queue.resolve(added: .init(heard: "BULL", meant: "pole"))
    let resolvedUnrelated = queue.resolve(added: .init(heard: "clod", meant: "cloud"))
    #expect(resolvedEdited)
    #expect(!resolvedUnrelated)
    #expect(queue.prefill(heard: "", meant: "") == .init(heard: "Male", meant: "Mail"))

    let skipped = queue.skip()
    #expect(skipped == .init(heard: "Male", meant: "Mail"))
    #expect(queue.pending == [.init(heard: "Tail", meant: "Tale")])
    let resolvedLast = queue.resolve(added: .init(heard: "Tail", meant: "Tale"))
    #expect(resolvedLast)
    #expect(queue.isEmpty)
    let skippedEmpty = queue.skip()
    #expect(skippedEmpty == nil)
    #expect(queue.prefill(heard: "", meant: "") == nil)
}
