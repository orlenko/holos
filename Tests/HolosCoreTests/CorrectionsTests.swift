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
