import Foundation
import Synchronization
import Testing
@testable import HolosCore

// The word list's "often heard as" words (docs/design.md "Word list"), and dictation's fix with them as candidate
// swaps. Every sentence is invented.

private let heardAsDate = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - The word list

@Test func aTermKeepsItsOftenHeardAsWords() {
    var list = WordList()
    list.add("Claude", at: heardAsDate)
    let added = list.addHeardAs(["cloud", " clot ", "Cloud", "claude", "", "clod"], to: "claude")
    #expect(added?.term == "Claude")
    #expect(added?.added == ["cloud", "clot", "clod"])
    #expect(added?.unchanged == ["Cloud"], "Another case of a word the term has is the same word.")
    #expect(added?.refused == ["claude"], "The term itself is never heard as itself.")
    #expect(list.heardAs(of: "CLAUDE") == ["cloud", "clot", "clod"])
    #expect(list.heardAsPairs == ["cloud", "clot", "clod"].map { Correction(heard: $0, meant: "Claude") })

    let removed = list.removeHeardAs(["CLOT", "nope"], from: "Claude")
    #expect(removed?.removed == ["clot"] && removed?.unchanged == ["nope"])
    #expect(list.heardAs(of: "Claude") == ["cloud", "clod"])

    let set = list.setHeardAs(["clod", "clawed"], for: "Claude")
    #expect(set?.added == ["clawed"] && set?.removed == ["cloud"] && set?.phrases == ["clod", "clawed"])
    #expect(list.setHeardAs([], for: "Claude")?.phrases == [])
    #expect(list.entries[0].heardAs == nil, "No words left is none, not an empty list.")
    #expect(list.addHeardAs(["cloud"], to: "Codex") == nil, "A term the list does not have.")
    #expect(list.heardAs(of: "Codex") == nil)
}

@Test func aTermKeepsAtMostTwentyHeardAsWords() {
    var list = WordList()
    list.add("Claude", at: heardAsDate)
    let change = list.addHeardAs((1...25).map { "word\($0)" } + ["!!", String(repeating: "x", count: 101)], to: "Claude")
    #expect(change?.added.count == WordList.maximumHeardAs)
    #expect(change?.refused.count == 7, "Past the limit, without a letter, or too long.")
}

@Test func commaListsSplitIntoWords() {
    #expect(WordList.heardAsList("cloud, clot,clod ,, ") == ["cloud", "clot", "clod"])
    #expect(WordList.heardAsList(" cloud   code ") == ["cloud code"])
}

@Test func anOlderWordListReadsAndWritesAsBefore() throws {
    // words.json written before "often heard as": no heardAs key.
    let older = """
        {"schemaVersion": 1, "entries": [
          {"text": "Keycloak", "addedAt": "2026-09-29T10:00:00Z", "source": "user"}]}
        """
    let read = try HolosJSON.decoder().decode(WordList.self, from: Data(older.utf8))
    #expect(read.terms == ["Keycloak"] && read.entries[0].heardAs == nil)
    let written = String(decoding: try HolosJSON.encoder().encode(read), as: UTF8.self)
    #expect(!written.contains("heardAs"), "A term without such words writes no key for them.")

    // A list with them round-trips; hand-edited words are cleaned as `addHeardAs` keeps them.
    let edited = """
        {"schemaVersion": 1, "entries": [
          {"text": "Claude", "addedAt": "2026-09-29T10:00:00Z", "source": "user",
           "heardAs": [" cloud ", "Cloud", "claude", "clot"]}]}
        """
    let withWords = try HolosJSON.decoder().decode(WordList.self, from: Data(edited.utf8))
    #expect(withWords.heardAs(of: "Claude") == ["cloud", "clot"])
    let again = try HolosJSON.decoder().decode(WordList.self, from: try HolosJSON.encoder().encode(withWords))
    #expect(again == withWords)
}

// MARK: - Where corrections apply

@Test func correctionMatchesSayWhereApplyReplaces() {
    let list = CorrectionList(entries: [Correction(heard: "a bundu", meant: "ubuntu"),
                                        Correction(heard: "Mac OS", meant: "macOS")])
    let text = "A bundu box runs mac os, and a  bundu laptop too."
    let matches = list.matches(in: text)
    #expect(matches.map(\.heard) == ["A bundu", "mac os", "a  bundu"])
    #expect(matches.map(\.meant) == ["Ubuntu", "macOS", "ubuntu"],
            "A sentence's capital is carried over; a saved capital means the lowercase is deliberate.")
    #expect(matches.map(\.range.location) == [0, 17, 29])
    #expect(list.apply(to: text) == "Ubuntu box runs macOS, and ubuntu laptop too.")
    #expect(list.applyCounting(to: text).count == 3)
    #expect(CorrectionList().matches(in: text).isEmpty)
}

// MARK: - The question to the model

@Test func onlyTheTermItselfReplacesThePlace() {
    for reply in ["Claude", "claude", " \"Claude\". ", "Claude\n", "“Claude”"] {
        #expect(HeardAsJudge.choosesTerm(reply, term: "Claude"), "\(reply)")
    }
    for reply in ["cloud", "Claude Code", "It is Claude", "Claud", "", "yes"] {
        #expect(!HeardAsJudge.choosesTerm(reply, term: "Claude"), "\(reply)")
    }
    #expect(HeardAsJudge.choosesTerm("claude  code", term: "Claude Code"))
    // A term's own marks are the term's, not wrappers to strip.
    for (reply, term) in [(".NET", ".NET"), ("\".NET\".", ".NET"), ("C#", "C#"), ("C#.", "C#"), ("C++", "C++"),
                          ("Inc.", "Inc."), ("(C#)", "C#")] {
        #expect(HeardAsJudge.choosesTerm(reply, term: term), "\(reply) for \(term)")
    }
    #expect(!HeardAsJudge.choosesTerm("C", term: "C#"))
    #expect(!HeardAsJudge.choosesTerm("NET", term: ".NET"))
}

@Test func theQuestionShowsThePlaceItsPassageAndTheTitle() {
    let question = HeardAsJudge.Question(title: "Weekly sync", before: "Yesterday I asked", heard: "cloud",
                                         after: "to refactor the parser.", term: "Claude")
    #expect(HeardAsJudge.prompt(question) == """
        Meeting title: Weekly sync
        Passage: Yesterday I asked [[cloud]] to refactor the parser.
        At [[cloud]], did the speaker say "cloud" or "Claude"?
        """)
    // A short segment gets its neighbours; a longer one says enough on its own.
    let text = "so I asked cloud to refactor it"
    let context = HeardAsJudge.context(of: 11..<16, in: text, previous: "It failed again.", next: "Then it passed.")
    #expect(context.before == "It failed again. so I asked" && context.after == "to refactor it Then it passed.")
    let longer = "so yesterday I asked cloud to refactor the parser"
    let alone = HeardAsJudge.context(of: 21..<26, in: longer, previous: "It failed again.", next: "Then it passed.")
    #expect(alone.before == "so yesterday I asked" && alone.after == "to refactor the parser")
    let long = String(repeating: "word ", count: 200)
    let cut = HeardAsJudge.context(of: 0..<0, in: "", previous: long, next: long)
    #expect(cut.before.count <= HeardAsJudge.contextBefore && cut.before.hasPrefix("word"))
    #expect(cut.after.count <= HeardAsJudge.contextAfter && cut.after.hasSuffix("word"))
}

/// The instructions a stand-in model was given.
private final class SeenInstructions: Sendable {
    private let text = Mutex("")
    var value: String { text.withLock { $0 } }
    func set(_ value: String) { text.withLock { $0 = value } }
}

@Test func theModelsAnswersDecideOnlyThatPlace() async {
    let question = HeardAsJudge.Question(title: "t", before: "I asked", heard: "cloud", after: "to help", term: "Claude")
    #expect(await HeardAsJudge.ask(question, model: { _, _ in "Claude" }, timeout: .seconds(30)) == .term)
    #expect(await HeardAsJudge.ask(question, model: { _, _ in "cloud" }, timeout: .seconds(30)) == .keep)
    #expect(await HeardAsJudge.ask(question, model: { _, _ in "Sure! Claude." }, timeout: .seconds(30)) == .keep)
    struct Refused: Error {}
    #expect(await HeardAsJudge.ask(question, model: { _, _ in throw Refused() }, timeout: .seconds(30)) == .failed)
    #expect(await HeardAsJudge.ask(question, model: { _, _ in
        try await Task.sleep(for: .seconds(3600))
        return "Claude"
    }, timeout: .milliseconds(10)) == .timedOut)
    // The instructions ask for a choice between the two words.
    let seen = SeenInstructions()
    _ = await HeardAsJudge.ask(question, model: { instructions, _ in
        seen.set(instructions)
        return "cloud"
    }, timeout: .seconds(30))
    #expect(seen.value.contains("Choose the one the speaker most likely said"))
}

// MARK: - Dictation's fix

/// What a stand-in model was asked: the fix's instructions, and the questions about heard-as places.
private final class HeardAsCalls: Sendable {
    private let state = Mutex<(fix: [String], questions: [String])>(([], []))
    var fixInstructions: [String] { state.withLock { $0.fix } }
    var questions: [String] { state.withLock { $0.questions } }
    func fix(_ instructions: String) { state.withLock { $0.fix.append(instructions) } }
    func question(_ prompt: String) { state.withLock { $0.questions.append(prompt) } }
}

/// A fixer whose model replies `reply` to the fix and `choose(question)` to each heard-as question.
private func heardAsFixer(heardAs: [Correction], reply: String, calls: HeardAsCalls = HeardAsCalls(),
                          choose: @escaping @Sendable (String) -> String = { _ in "Claude" }) -> TranscriptFixer {
    var fixer = TranscriptFixer(corrections: CorrectionList(), wordList: ["Claude"], heardAs: heardAs,
                                referenceBudget: 500, timeout: .seconds(30), language: "en-US") { instructions, prompt in
        guard prompt.hasPrefix("Text: ") else {
            calls.question(prompt)
            return choose(prompt)
        }
        calls.fix(instructions)
        return reply
    }
    fixer.spellingBudget = .seconds(60)
    return fixer
}

private let claudePairs = ["cloud", "clot"].map { Correction(heard: $0, meant: "Claude") }

@Test func dictationAsksAboutEachPlaceAHeardAsWordWasSaid() async {
    let calls = HeardAsCalls()
    let fixer = heardAsFixer(heardAs: claudePairs, reply: "I asked cloud to fix the parser", calls: calls)
    let result = await fixer.fix("I asked cloud to fix the parser", isFinal: false)
    #expect(result.outcome == .fixed && result.text == "I asked Claude to fix the parser")
    #expect(calls.questions == ["""
        Passage: I asked [[cloud]] to fix the parser
        At [[cloud]], did the speaker say "cloud" or "Claude"?
        """])
    #expect(calls.fixInstructions.allSatisfy { !$0.contains("Claude") },
            "The fix itself is never told the pairs: told them, the model put the term in sentences about the cloud.")
}

@Test func dictationKeepsTheHeardWordUnlessTheModelChoosesTheTerm() async {
    for reply in ["cloud", "Sure, Claude.", "yes", ""] {
        let fixer = heardAsFixer(heardAs: claudePairs, reply: "We moved the backups to the cloud",
                                 choose: { _ in reply })
        let result = await fixer.fix("We moved the backups to the cloud", isFinal: false)
        #expect(result.outcome == .unchanged && result.text == "We moved the backups to the cloud", "\(reply)")
    }
    // No pairs, no question.
    let calls = HeardAsCalls()
    _ = await heardAsFixer(heardAs: [], reply: "I asked cloud", calls: calls).fix("I asked cloud", isFinal: false)
    #expect(calls.questions.isEmpty)
}

@Test func theFixAloneNeverPutsTheTermThere() async {
    // The fix's own reply swapping the word is refused by the guard, as before; the question keeps the word.
    let fixer = heardAsFixer(heardAs: claudePairs, reply: "I asked Claude to fix the parser", choose: { _ in "cloud" })
    let result = await fixer.fix("I asked cloud to fix the parser", isFinal: false)
    #expect(result.outcome == .rejected && result.text == "I asked cloud to fix the parser")
}

@Test func aWordALearnedCorrectionProducedIsNeverAskedAbout() async {
    // "clawed -> cloud" is learned, and "cloud" is also heard for "Claude": the corrected "cloud" stays.
    let calls = HeardAsCalls()
    var fixer = TranscriptFixer(corrections: CorrectionList(entries: [Correction(heard: "clawed", meant: "cloud")]),
                                wordList: ["Claude"], heardAs: claudePairs, referenceBudget: 500,
                                timeout: .seconds(30), language: "en-US") { _, prompt in
        guard prompt.hasPrefix("Text: ") else {
            calls.question(prompt)
            return "Claude"
        }
        return "I asked cloud to fix the parser"
    }
    fixer.spellingBudget = .seconds(60)
    let result = await fixer.fix("I asked cloud to fix the parser", isFinal: false)
    #expect(result.text == "I asked cloud to fix the parser" && result.outcome == .unchanged)
    #expect(calls.questions.isEmpty)
    #expect(TranscriptFixer.heardAsPlaces(in: "Cloud runs and clot runs", pairs: claudePairs,
                                          protecting: [Correction(heard: "clawed", meant: "cloud")])
        .map(\.heard) == ["clot"])
}

@Test func aTermKeepsItsSavedSpellingAtASentenceStart() async {
    let pairs = [Correction(heard: "eye phone", meant: "iPhone")]
    var fixer = TranscriptFixer(corrections: CorrectionList(), wordList: ["iPhone"], heardAs: pairs,
                                referenceBudget: 500, timeout: .seconds(30), language: "en-US") { _, prompt in
        prompt.hasPrefix("Text: ") ? "Eye phone sales are up" : "iPhone"
    }
    fixer.spellingBudget = .seconds(60)
    let result = await fixer.fix("Eye phone sales are up", isFinal: false)
    #expect(result.text == "iPhone sales are up")
}

@Test func aFailedQuestionKeepsThePlaceAndTheFix() async {
    struct Refused: Error {}
    var fixer = TranscriptFixer(corrections: CorrectionList(), wordList: ["Claude"], heardAs: claudePairs,
                                referenceBudget: 500, timeout: .seconds(30), language: "en-US") { _, prompt in
        guard prompt.hasPrefix("Text: ") else { throw Refused() }
        return "Then cloud fixed the parser."
    }
    fixer.spellingBudget = .seconds(60)
    let result = await fixer.fix("Then cloud fixed the parcer.", isFinal: true)
    #expect(result.outcome == .fixed && result.text == "Then cloud fixed the parser.")
}

@Test func aTimedOutQuestionKeepsThePlaceAndTheFix() async {
    var fixer = TranscriptFixer(corrections: CorrectionList(), wordList: ["Claude"], heardAs: claudePairs,
                                referenceBudget: 500, timeout: .milliseconds(50), language: "en-US") { _, prompt in
        guard prompt.hasPrefix("Text: ") else {
            try await Task.sleep(for: .seconds(3600))
            return "Claude"
        }
        return "Then cloud fixed the parser."
    }
    fixer.spellingBudget = .seconds(60)
    let result = await fixer.fix("Then cloud fixed the parcer.", isFinal: true)
    #expect(result.outcome == .fixed && result.text == "Then cloud fixed the parser.")
}

@Test func aTermJoinsTheFixAndOnlyItsPlaceChanges() async {
    // The fix corrects a non-word; the question then puts the term at the heard word, and only there.
    let fixer = heardAsFixer(heardAs: claudePairs, reply: "Then cloud fixed the parser.",
                             choose: { $0.contains("[[cloud]] fixed") ? "Claude" : "cloud" })
    let result = await fixer.fix("Then cloud fixed the parcer.", isFinal: true)
    #expect(result.outcome == .fixed && result.text == "Then Claude fixed the parser.")
    // A sentence's capital is kept by the term; each place is asked on its own, at most three per chunk.
    let calls = HeardAsCalls()
    let many = heardAsFixer(heardAs: claudePairs, reply: "Cloud and cloud and clot and cloud", calls: calls,
                            choose: { $0.contains("Passage: [[Cloud]]") ? "Claude" : "cloud" })
    let swapped = await many.fix("Cloud and cloud and clot and cloud", isFinal: false)
    #expect(swapped.text == "Claude and cloud and clot and cloud")
    #expect(calls.questions.count == TranscriptFixer.maximumHeardAsQuestions)
}
