import Testing
@testable import HolosCore

private func retaining(_ text: String, original: String = "") -> ResultRetention {
    var retention = ResultRetention()
    retention.begin()
    _ = retention.conclude(DictationResult(text: text, original: original))
    return retention
}

@Test func aDictationThatProducesNothingKeepsThePreviousResult() {
    var retention = retaining(" the words that were not typed", original: "the words that were not typed as heard")
    let previous = retention.kept
    // Cancelled, released before listening, or nothing recognized: the dictation concludes with no text.
    retention.begin()
    #expect(retention.kept == previous)  // still offered while the new dictation runs
    #expect(retention.conclude(DictationResult()) == .keptPrevious)
    #expect(retention.kept == previous)
    retention.begin()
    #expect(retention.conclude(DictationResult(text: "  \n", original: " ")) == .keptPrevious)
    #expect(retention.kept == previous)
}

@Test func aDictationWithTextOrAnOriginalReplacesThePreviousResult() {
    var retention = retaining("first")
    retention.begin()
    #expect(retention.conclude(DictationResult(text: "second")) == .replaced)
    #expect(retention.kept == DictationResult(text: "second"))
    // A cancelled dictation whose fix already changed written text leaves only Copy Original; it belongs to that
    // dictation, so the pair is never mixed with the previous Copy Result.
    retention.begin()
    #expect(retention.conclude(DictationResult(text: "", original: "as heard")) == .replaced)
    #expect(retention.kept == DictationResult(text: "", original: "as heard"))
}

@Test func onlyTheDictationThatBeganConcludes() {
    var retention = retaining("kept")
    // A reset after the result (Discard, the expiry) publishes another end; it must not replace or clear anything.
    #expect(retention.conclude(DictationResult(text: "stale")) == .nothing)
    #expect(retention.kept == DictationResult(text: "kept"))
    #expect(!retention.awaiting)
}

@Test func withNoEarlierResultAnEmptyDictationConcludesWithNothing() {
    var retention = ResultRetention()
    retention.begin()
    #expect(retention.conclude(DictationResult()) == .nothing)
    #expect(retention.kept.isEmpty)
}

@Test func discardDuringADictationLetsThatDictationStillConclude() {
    var retention = retaining("old")
    retention.begin()
    retention.discard()  // the old result's expiry fired while the new dictation was running
    #expect(retention.kept.isEmpty)
    #expect(retention.awaiting)
    #expect(retention.conclude(DictationResult()) == .nothing)
    retention.begin()
    #expect(retention.conclude(DictationResult(text: "new")) == .replaced)
    #expect(retention.kept == DictationResult(text: "new"))
}
