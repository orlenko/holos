import Foundation
import Synchronization
import Testing
@testable import HolosCore

@Test func guardAcceptsAMisheardWordFix() {
    #expect(AIFixGuard.check(original: "When a press escape they don't disappear.",
                             fixed: "When I press escape, they don't disappear.") == .accept)
    #expect(AIFixGuard.check(original: "I would like to by a new pear of shoes for the whether this weekend.",
                             fixed: "I would like to buy a new pair of shoes for the weather this weekend.") == .accept)
    #expect(AIFixGuard.check(original: "and then it failed because of a missing semi colon",
                             fixed: "and then it failed because of a missing semicolon") == .accept)
    #expect(AIFixGuard.check(original: "meet me there", fixed: "Meet me there.") == .accept)
}

@Test func guardTreatsTheSameTextAsNothingToDo() {
    #expect(AIFixGuard.check(original: "Nothing to fix here.", fixed: "Nothing to fix here.") == .unchanged)
    #expect(AIFixGuard.check(original: "Nothing to fix here.", fixed: "  Nothing to fix here.\n") == .unchanged)
}

@Test func guardRejectsRewordingsAndAdditions() {
    // A reply that answers the dictation instead of fixing it.
    #expect(AIFixGuard.check(original: "Can you meat me at the station at five?",
                             fixed: "I cannot meet you at the station at five.") == .reject(.tooManyEdits))
    #expect(AIFixGuard.check(original: "the results were quite good overall",
                             fixed: "overall the outcome looked very good") == .reject(.tooManyEdits))
    #expect(AIFixGuard.check(original: "The weather is lovely today.",
                             fixed: "The weather is lovely today. Thanks for listening.") == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "The weather is lovely today and we plan to walk to the lake.",
                             fixed: "The weather is lovely today and we plan to walk to the lake GitHub Holos macOS")
        == .reject(.wordCountChanged))
    #expect(AIFixGuard.check(original: "first part second part", fixed: "first part\nsecond part")
        == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "we are done for today", fixed: "Corrected: we are done for today")
        == .reject(.changedStructure))
}

@Test func guardRejectsAnyMarkOtherThanCommasAndApostrophes() {
    // Relocated marks: the same words and the same count of each mark, in other places.
    #expect(AIFixGuard.check(original: "Wait here. Don't leave", fixed: "Wait here Don't. Leave")
        == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "time: five", fixed: "Corrected: time five") == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "a b. c d", fixed: "a. b c d") == .reject(.changedStructure))
    // Removed, added or swapped marks inside the chunk.
    #expect(AIFixGuard.check(original: "Wait here. Don't leave", fixed: "Wait here, don't leave")
        == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "is it done then we go", fixed: "is it done? then we go")
        == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "he said great", fixed: "he said \"great\"") == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "see (below) now", fixed: "see below now") == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "Wait here. Don't leave", fixed: "Wait here! Don't leave")
        == .reject(.changedStructure))
    // Commas and apostrophes come and go; words change within the budget with the marks where they were.
    #expect(AIFixGuard.check(original: "Wait here. Dont leave", fixed: "Wait, here. Don't leave,") == .accept)
    #expect(AIFixGuard.check(original: "I went their. Then we left", fixed: "I went there. Then, we left.")
        == .accept)
    #expect(AIFixGuard.check(original: "x. y", fixed: "y. x") == .accept)  // two substitutions, the mark stays put
    // Closing marks may change at the very end, including before closing quotes.
    #expect(AIFixGuard.check(original: "he called it “great”", fixed: "he called it “great.”") == .accept)
    #expect(AIFixGuard.check(original: "Is it done?", fixed: "Is it done?!") == .accept)
}

@Test func guardRejectsBigDeletionsAndEmptyReplies() {
    let original = "I think we should move the release to next week because the tests are still failing on the build machine"
    #expect(AIFixGuard.check(original: original, fixed: "We should move the release to next week.")
        == .reject(.wordCountChanged))
    #expect(AIFixGuard.check(original: original, fixed: "") == .reject(.empty))
    #expect(AIFixGuard.check(original: original, fixed: "  \n") == .reject(.empty))
    #expect(AIFixGuard.check(original: "hello there", fixed: "...") == .reject(.empty))
}

@Test func editLimitGrowsWithLength() {
    let words = (1...30).map { "word\($0)" }
    var changed = words
    for index in [3, 9, 15, 21, 27] { changed[index] = "other\(index)" }  // 5 edits; 20 % of 30 is 6
    #expect(AIFixGuard.check(original: words.joined(separator: " "), fixed: changed.joined(separator: " ")) == .accept)
    for index in [1, 5] { changed[index] = "other\(index)" }  // 7 edits
    #expect(AIFixGuard.check(original: words.joined(separator: " "), fixed: changed.joined(separator: " "))
        == .reject(.tooManyEdits))
    #expect(AIFixGuard.editDistance(["a", "b", "c"], ["a", "x", "c", "d"]) == 2)
    // Joining or splitting words is one edit.
    #expect(AIFixGuard.editDistance(["a", "semi", "colon"], ["a", "semicolon"]) == 1)
    #expect(AIFixGuard.editDistance(["a", "semicolon"], ["a", "semi", "colon"]) == 1)
    #expect(AIFixGuard.editDistance([], ["a", "b"]) == 2)
    #expect(AIFixGuard.editDistance(["a"], []) == 1)
}

@Test func keepsTheEdgesOfAChunkInTheMiddleOfASentence() {
    #expect(AIFixGuard.keepingEdges(of: "their going to review it", in: "They're going to review it.", isFinal: false)
        == "they're going to review it")
    // The end of the dictation may gain its closing punctuation.
    #expect(AIFixGuard.keepingEdges(of: "their going to review it", in: "They're going to review it.", isFinal: true)
        == "they're going to review it.")
    #expect(AIFixGuard.keepingEdges(of: "i think so", in: "I think so", isFinal: false) == "I think so")
    #expect(AIFixGuard.keepingEdges(of: "get hub is down", in: "GitHub is down", isFinal: false) == "GitHub is down")
    #expect(AIFixGuard.keepingEdges(of: "Is it done?", in: "Is it done?", isFinal: false) == "Is it done?")
}

@Test func sanitizesTheLabelAndQuotes() {
    #expect(AIFixGuard.sanitized("Text: When I press escape", for: "When a press escape") == "When I press escape")
    #expect(AIFixGuard.sanitized("\"When I press escape\"", for: "When a press escape") == "When I press escape")
    #expect(AIFixGuard.sanitized("\"quoted\"", for: "\"quoted\"") == "\"quoted\"")
    // A "Text:" the speaker dictated is content; only the prompt's own label is removed.
    #expect(AIFixGuard.sanitized("Text: buy milk", for: "Text: buy milk") == "Text: buy milk")
    #expect(AIFixGuard.sanitized("Text: buy milk", for: "text: by milk") == "Text: buy milk")
    #expect(AIFixGuard.sanitized("Text: Text: buy milk", for: "Text: by milk") == "Text: buy milk")
}

@Test func fixerKeepsADictatedTextLabel() async {
    let echo = await fixer { _, prompt in String(prompt.dropFirst(6)) }.fix("Text: buy milk", isFinal: true)
    #expect(echo == .init(text: "Text: buy milk", outcome: .unchanged))
    let wrapped = await fixer { _, prompt in prompt }.fix("Text: buy milk", isFinal: true)
    #expect(wrapped == .init(text: "Text: buy milk", outcome: .unchanged))
}

@Test func withholdsTheWholeAddedClosingRun() {
    #expect(AIFixGuard.keepingEdges(of: "are you sure", in: "Are you sure?!", isFinal: false) == "are you sure")
    #expect(AIFixGuard.keepingEdges(of: "and then", in: "And then...", isFinal: false) == "and then")
    #expect(AIFixGuard.keepingEdges(of: "and then", in: "And then…", isFinal: false) == "and then")
    #expect(AIFixGuard.keepingEdges(of: "wait for me,", in: "Wait for me?!", isFinal: false) == "wait for me,")
    #expect(AIFixGuard.keepingEdges(of: "Is it done?", in: "Is it done?!", isFinal: false) == "Is it done?")
    #expect(AIFixGuard.keepingEdges(of: "are you sure", in: "Are you sure?!", isFinal: true) == "are you sure?!")
}

@Test func withholdsAClosingRunBeforeClosingQuotesAndBrackets() {
    #expect(AIFixGuard.keepingEdges(of: "he called it “great”", in: "He called it “great.”", isFinal: false)
        == "he called it “great”")
    #expect(AIFixGuard.keepingEdges(of: "we will ship (soon)", in: "We will ship (soon?!)", isFinal: false)
        == "we will ship (soon)")
    #expect(AIFixGuard.keepingEdges(of: "she said \"wait,\"", in: "She said \"wait.\"", isFinal: false)
        == "she said \"wait,\"")
    #expect(AIFixGuard.keepingEdges(of: "he called it “great”", in: "He called it “great.”", isFinal: true)
        == "he called it “great.”")
    #expect(AIFixGuard.closingRun(of: "“great.”") == ".")
    #expect(AIFixGuard.closingRun(of: "the dogs'") == "")
}

@Test func fixerHoldsBackAClosingMarkBeforeAClosingQuote() async {
    let quoted = await fixer { _, _ in "He called it “great.”" }.fix(" he called it “great”", isFinal: false)
    #expect(quoted == .init(text: " he called it “great”", outcome: .unchanged, withheldClosing: "."))
    let fixed = await fixer { _, _ in "He called it “great.”" }.fix(" he cold it “great”", isFinal: false)
    #expect(fixed == .init(text: " he called it “great”", outcome: .fixed, withheldClosing: "."))
    // The chunk already ended with a comma inside the quote: nothing is held back.
    let comma = await fixer { _, _ in "She said \"wait.\"" }.fix("she said \"wait,\"", isFinal: false)
    #expect(comma == .init(text: "she said \"wait,\"", outcome: .unchanged))
}

@Test func fixerHoldsBackACompoundClosingRun() async {
    let asked = await fixer { _, _ in "Are you sure?!" }.fix(" are you sure", isFinal: false)
    #expect(asked == .init(text: " are you sure", outcome: .unchanged, withheldClosing: "?!"))
    let trailing = await fixer { _, _ in "And then they left..." }.fix("and than they left", isFinal: false)
    #expect(trailing == .init(text: "and then they left", outcome: .fixed, withheldClosing: "..."))
}

@Test func copyResultOffersTheFixHolosTriedToWrite() {
    // The fix made on release, whose write failed.
    #expect(AIFixUnwritten.attempted(" their here", fixedRest: " they're here", failedWrite: nil) == " they're here")
    // A streamed chunk whose fixed write failed, then the recognized text after it.
    #expect(AIFixUnwritten.attempted(" their here and gone", fixedRest: nil,
                                     failedWrite: (chunk: " their here", text: " they're here"))
        == " they're here and gone")
    // The final transcript is trimmed while the chunk kept its leading space.
    #expect(AIFixUnwritten.attempted("their here", fixedRest: nil,
                                     failedWrite: (chunk: " their here", text: " they're here")) == "they're here")
    // No fix covers the start: the recognized text.
    #expect(AIFixUnwritten.attempted(" something else", fixedRest: nil,
                                     failedWrite: (chunk: " their here", text: " they're here")) == " something else")
    #expect(AIFixUnwritten.attempted(" their here", fixedRest: nil, failedWrite: nil) == " their here")
}

@Test func referencePrefersRelatedCorrectionsWithinBudget() {
    let entries = [
        Correction(heard: "get hub", meant: "GitHub"),
        Correction(heard: "mac os", meant: "macOS"),
        Correction(heard: "bull request", meant: "pull request"),
        Correction(heard: "code x", meant: "Codex"),
    ]
    // Only related pairs: unrelated ones led the model to put their spellings into unrelated text.
    #expect(AIFixReference.select(from: entries, for: "I opened a bull request", budget: 1_000) == [entries[2]])
    #expect(AIFixReference.select(from: entries, for: "nothing related", budget: 1_000).isEmpty)
    // Relevance also counts the meant side, case-insensitively; the most recent pair comes first.
    #expect(AIFixReference.select(from: entries, for: "is github down on mac", budget: 1_000)
        == [entries[1], entries[0]])
    // A pair that does not fit is skipped, and a later one that fits is still taken.
    let short = Correction(heard: "get hub", meant: "GitHub")
    let long = Correction(heard: "mac os ventura beta build", meant: "macOS Ventura beta build")
    let budget = AIFixReference.estimatedTokens(short)
    #expect(AIFixReference.estimatedTokens(long) > budget)
    #expect(AIFixReference.select(from: [short, long], for: "is github down on mac", budget: budget) == [short])
    #expect(AIFixReference.select(from: entries, for: "github", budget: 0).isEmpty)
}

@Test func instructionsListTheReferencePairs() {
    let text = TranscriptFixer.instructions(reference: [Correction(heard: "get hub", meant: "GitHub")])
    #expect(text.contains("get hub -> GitHub"))
    #expect(TranscriptFixer.instructions(reference: []) == TranscriptFixer.baseInstructions)
}

private func fixer(corrections: CorrectionList = CorrectionList(), timeout: Duration = .seconds(5),
                   _ model: @escaping TranscriptFixer.Model) -> TranscriptFixer {
    TranscriptFixer(corrections: corrections, referenceBudget: 500, timeout: timeout, model: model)
}

@Test func fixerKeepsTheChunkSpacingAndAcceptsASmallFix() async {
    let seen = Mutex<[String]>([])
    let fix = fixer { _, prompt in
        seen.withLock { $0.append(prompt) }
        return "When I press escape they don't disappear."
    }
    let result = await fix.fix(" When a press escape they don't disappear. ", isFinal: false)
    #expect(result == .init(text: " When I press escape they don't disappear. ", outcome: .fixed))
    #expect(seen.withLock { $0 } == ["Text: When a press escape they don't disappear."])
}

@Test func fixerKeepsTheChunkWhenTheReplyIsRefused() async {
    let answer = fixer { _, _ in "I cannot meet you at the station at five." }
    let refused = await answer.fix("Can you meat me at the station at five?", isFinal: true)
    #expect(refused == .init(text: "Can you meat me at the station at five?", outcome: .rejected, rejection: .tooManyEdits))

    let same = await fixer { _, prompt in String(prompt.dropFirst(6)) }.fix("all good here", isFinal: false)
    #expect(same == .init(text: "all good here", outcome: .unchanged))

    struct Failure: Error {}
    let failing = await fixer { _, _ in throw Failure() }.fix("all good here", isFinal: false)
    #expect(failing == .init(text: "all good here", outcome: .failed))
}

@Test func fixerAppliesLearnedCorrectionsToTheReply() async {
    let corrections = CorrectionList(entries: [Correction(heard: "get hub", meant: "GitHub")])
    let seenInstructions = Mutex("")
    let fix = fixer(corrections: corrections) { instructions, _ in
        seenInstructions.withLock { $0 = instructions }
        return "I opened a pull request on get hub"
    }
    let result = await fix.fix("I opened a bull request on GitHub", isFinal: false)
    #expect(result.text == "I opened a pull request on GitHub")
    #expect(result.outcome == .fixed)
    #expect(seenInstructions.withLock { $0 }.contains("get hub -> GitHub"))
}

@Test func fixerCorrectsOnlyWordsTheModelChanged() async {
    // A valid chain: "foo" was already corrected to "bar" before the chunk reached the fixer.
    let chain = CorrectionList(entries: [Correction(heard: "foo", meant: "bar"), Correction(heard: "bar", meant: "baz")])
    let echo = await fixer(corrections: chain) { _, prompt in String(prompt.dropFirst(6)) }
        .fix("I said bar", isFinal: true)
    #expect(echo == .init(text: "I said bar", outcome: .unchanged))
    let punctuated = await fixer(corrections: chain) { _, _ in "I said bar, then left." }
        .fix("I said bar then left", isFinal: true)
    #expect(punctuated == .init(text: "I said bar, then left.", outcome: .fixed))
    // A word the model introduced gets one pass of the rules, like recognized text does.
    let introduced = await fixer(corrections: chain) { _, _ in "I said foo" }.fix("I said fool", isFinal: true)
    #expect(introduced == .init(text: "I said bar", outcome: .fixed))
    // Raw "fool foo" reached the fixer as "fool bar"; the model changed the first word into "bar". Only that
    // occurrence gets the rules, not its twin that was already corrected.
    let twin = await fixer(corrections: chain) { _, _ in "bar bar" }.fix("fool bar", isFinal: true)
    #expect(twin == .init(text: "baz bar", outcome: .fixed))
}

@Test func changedWordsArePositionalOrAbsentFromTheOriginal() {
    // Same count: position by position.
    #expect(AIFixGuard.changedWordRanges(from: "fool bar", to: "bar bar") == [NSRange(location: 0, length: 3)])
    #expect(AIFixGuard.changedWordRanges(from: "bar fool", to: "bar bar") == [NSRange(location: 4, length: 3)])
    // Different counts: only words found nowhere in the original, so a duplicate is never picked.
    #expect(AIFixGuard.changedWordRanges(from: "fool bar x", to: "bar bar").isEmpty)
    #expect(AIFixGuard.changedWordRanges(from: "fool bar", to: "bar bar baz").map(\.location) == [8])
    #expect(AIFixGuard.changedWordRanges(from: "I don’t know", to: "I don't know").isEmpty)
}

@Test func copyOriginalStaysWheneverAFixChangedWhatHolosWroteOrOffers() {
    // A fixed chunk was written, then recognition failed, the capture failed, or the dictation was cancelled.
    #expect(AIFixOriginal.heard("their here and gone", written: " they're here", writtenOriginal: " their here")
        == "their here and gone")
    // The rest Holos wrote or offers is the fix.
    #expect(AIFixOriginal.heard("their here", written: "", writtenOriginal: "",
                                offered: " they're here", recognized: " their here") == "their here")
    // No fix changed anything: no Copy Original.
    #expect(AIFixOriginal.heard("all good", written: " all", writtenOriginal: " all",
                                offered: " good", recognized: " good") == nil)
    #expect(AIFixOriginal.heard("", written: "a", writtenOriginal: "b") == nil)
}

@Test func correctionsCanBeLimitedToChangedRanges() {
    let list = CorrectionList(entries: [Correction(heard: "get hub", meant: "GitHub")])
    let text = "get hub and get hub"
    #expect(list.apply(to: text, onlyTouching: [NSRange(location: 12, length: 3)]) == "get hub and GitHub")
    #expect(list.apply(to: text, onlyTouching: []) == text)
    #expect(AIFixGuard.changedWordRanges(from: "When a press escape", to: "when I press escape,")
        == [NSRange(location: 5, length: 1)])
    #expect(AIFixGuard.changedWordRanges(from: "a b c", to: "a b c d").map(\.location) == [6])
    #expect(AIFixGuard.changedWordRanges(from: "a b c", to: "a c").isEmpty)
}

@Test func fixerHoldsBackAClosingMarkForAChunkThatMayContinue() async {
    let fix = fixer { _, _ in "They're going to review it tomorrow." }
    let middle = await fix.fix(" their going to review it tomorrow", isFinal: false)
    #expect(middle == .init(text: " they're going to review it tomorrow", outcome: .fixed, withheldClosing: "."))
    let last = await fix.fix(" their going to review it tomorrow", isFinal: true)
    #expect(last == .init(text: " they're going to review it tomorrow.", outcome: .fixed))
    // Only the period was added: the chunk is unchanged, but the mark is still offered.
    let period = await fixer { _, _ in "All good here." }.fix("all good here", isFinal: false)
    #expect(period == .init(text: "all good here", outcome: .unchanged, withheldClosing: "."))
    // A comma the model turned into a period stays a comma, and nothing is held back.
    let comma = await fixer { _, _ in "Wait for me." }.fix("wait for me,", isFinal: false)
    #expect(comma == .init(text: "wait for me,", outcome: .unchanged))
}

@Test func fixerSkipsLongOrWordlessChunksWithoutAskingTheModel() async {
    let calls = Mutex(0)
    let fix = fixer { _, prompt in
        calls.withLock { $0 += 1 }
        return prompt
    }
    let long = Array(repeating: "word", count: TranscriptFixer.maximumWords + 1).joined(separator: " ")
    #expect(await fix.fix(long, isFinal: true) == .init(text: long, outcome: .skipped))
    #expect(await fix.fix(" ... ", isFinal: true) == .init(text: " ... ", outcome: .skipped))
    #expect(calls.withLock { $0 } == 0)
}

@Test func fixerGivesUpOnASlowModel() async {
    let fix = fixer(timeout: .milliseconds(50)) { _, _ in
        // Ignores cancellation, like a hung platform call: the timeout must not wait for it.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
        }
        return "too late"
    }
    let started = ContinuousClock.now
    let result = await fix.fix("a slow one", isFinal: false)
    #expect(result == .init(text: "a slow one", outcome: .timedOut))
    #expect(started.duration(to: .now) < .milliseconds(900))
}
