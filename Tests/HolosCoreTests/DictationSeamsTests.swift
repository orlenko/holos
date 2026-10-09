import Foundation
import Synchronization
import Testing
@testable import HolosCore

// Pauses inside a sentence (docs/design.md "Pauses inside a sentence"): the recognizer writes each stretch of speech
// between pauses as a sentence, so a capital lands where the speaker only paused. Made-up sentences throughout.

/// Seams with the system spell checker and name tagger, as dictation uses them.
private func system(_ language: String = "en-US", terms: [String] = []) -> DictationSeams {
    DictationSeams(language: language, terms: terms)
}

/// `seams.join(pieces)` once the spell checker has answered about the pauses' words, as live dictation has them by
/// the time a result is final (it asks while the result is still being recognized).
private func joined(_ seams: DictationSeams, _ pieces: [String]) async -> String {
    await seams.prepare(pieces, within: .seconds(30))
    return seams.join(pieces)
}

/// Seams whose spell checker answers on the spot: every word known, or as `knows` says; names as `names` says.
private func scripted(_ language: String = "en-US", terms: [String] = [],
                      knows: @escaping @Sendable (String) -> Bool = { _ in true },
                      names: Set<String> = []) -> DictationSeams {
    DictationSeams(language: language, terms: terms, spelling: SeamSpelling(queue: nil, lookup: knows),
                   isName: { text, range in names.contains(String(text[range])) })
}

@Test func aPauseInsideASentenceLowersTheNextWord() async {
    let seams = system()
    #expect(await joined(seams, ["We are cleaning up our big", "Pull request splitting it into parts"])
        == "We are cleaning up our big pull request splitting it into parts")
    #expect(await joined(seams, ["I am putting together the", "Simple web app for the team"])
        == "I am putting together the simple web app for the team")
    #expect(await joined(seams, ["You're saying that", "It will not have a menu"])
        == "You're saying that it will not have a menu")
    // A comma or a colon at the pause does not end the sentence.
    #expect(await joined(seams, ["When it loads,", "Maybe we can check the log"])
        == "When it loads, maybe we can check the log")
    #expect(await joined(seams, ["There are two steps:", "First we build"]) == "There are two steps: first we build")
}

@Test func theEndOfASentenceKeepsTheCapital() {
    let seams = scripted()
    #expect(seams.join(["That works.", "Maybe we can try it"]) == "That works. Maybe we can try it")
    #expect(seams.join(["Does it work?", "Then we ship"]) == "Does it work? Then we ship")
    #expect(seams.join(["Stop!", "Then wait"]) == "Stop! Then wait")
    #expect(seams.join(["And so…", "Then it ended"]) == "And so… Then it ended")
    #expect(seams.join(["He said “wait.”", "Then he left"]) == "He said “wait.” Then he left")
    #expect(seams.join(["(It was late.)", "Then we left"]) == "(It was late.) Then we left")
    // The first result keeps its capital.
    #expect(seams.join(["Maybe later"]) == "Maybe later")
}

@Test func frenchQuotesWithSpacesBeforeThemEndTheSentence() {
    let seams = scripted("fr-FR")
    #expect(seams.join(["Il a dit « C’est fini. »", "Ensuite on part"]) == "Il a dit « C’est fini. » Ensuite on part")
    // No-break and narrow no-break spaces, and closing marks in any order.
    #expect(seams.join(["Il a dit « C’est fini.\u{00A0}»", "Ensuite on part"])
        == "Il a dit « C’est fini.\u{00A0}» Ensuite on part")
    #expect(seams.join(["Il a dit « C’est fini ?\u{202F}»", "Ensuite on part"])
        == "Il a dit « C’est fini ?\u{202F}» Ensuite on part")
    #expect(seams.join(["(il a dit « c’est fini. » )", "Ensuite on part"])
        == "(il a dit « c’est fini. » ) Ensuite on part")
    // A quote that closes no sentence does not end one.
    #expect(seams.join(["il a dit « fini »", "Ensuite on part"]) == "il a dit « fini » ensuite on part")
}

@Test func aLineBreakAnywhereInTheSpacesAtThePauseKeepsTheCapital() {
    let seams = scripted()
    #expect(seams.join(["The list:\n", "First the code"]) == "The list: First the code")
    #expect(seams.join(["The list:", "\nFirst the code"]) == "The list: First the code")
    #expect(seams.join(["The list:\n ", "First the code"]) == "The list: First the code")
    #expect(seams.join(["The list:", " \nFirst the code"]) == "The list: First the code")
    #expect(seams.join(["The list: \r\n\t", "First the code"]) == "The list: First the code")
    // A result of spaces and a line break alone, between two others.
    #expect(seams.join(["The list:", " \n ", "First the code"]) == "The list: First the code")
    // Spaces without a line break do not count.
    #expect(seams.join(["The list: ", " First the code"]) == "The list: first the code")
}

@Test func thePronounIKeepsItsCapitalInEnglish() {
    let seams = scripted()
    #expect(seams.join(["Tomorrow morning", "I will send the notes"]) == "Tomorrow morning I will send the notes")
    #expect(seams.join(["and then", "I'm done"]) == "and then I'm done")
    #expect(seams.join(["and then", "I’ll call"]) == "and then I’ll call")
    #expect(seams.join(["so", "I've seen it and", "I'd say yes"]) == "so I've seen it and I'd say yes")
}

@Test func acronymsMixedCaseAndSymbolsKeepTheirCapitals() {
    let seams = scripted()
    #expect(seams.join(["we merged the", "PR yesterday"]) == "we merged the PR yesterday")
    #expect(seams.join(["it ran on", "NASA hardware"]) == "it ran on NASA hardware")
    #expect(seams.join(["we can try", "GPT-4 later"]) == "we can try GPT-4 later")
    #expect(seams.join(["they use", "McDonald's data"]) == "they use McDonald's data")
    #expect(seams.join(["it works on", "macOS now"]) == "it works on macOS now")
    #expect(seams.join(["I left my", "iPhone there"]) == "I left my iPhone there")
    #expect(seams.join(["we wrote it in", "C# first"]) == "we wrote it in C# first")
    // A plain capitalized word with a hyphen is lowered.
    #expect(seams.join(["it was a", "Well-known bug"]) == "it was a well-known bug")
}

@Test func wordListTermsCorrectionsAndNamesKeepTheirCapitals() {
    // Without the terms, every word here is lowered.
    #expect(scripted().join(["send it over", "Signal tonight"]) == "send it over signal tonight")
    let terms = DictationSeams.terms(wordList: ["Signal", "pull request"],
                                     corrections: CorrectionList(entries: [Correction(heard: "at less",
                                                                                      meant: "Atlas board")]),
                                     names: ["Will Archer"])
    let seams = scripted(terms: terms)
    #expect(seams.join(["send it over", "Signal tonight"]) == "send it over Signal tonight")
    #expect(seams.join(["open the", "Atlas board"]) == "open the Atlas board")
    #expect(seams.join(["ask", "Will about it"]) == "ask Will about it")
    // A term written in lowercase does not keep a capital.
    #expect(seams.join(["our big", "Pull request"]) == "our big pull request")
}

@Test func namesKeepTheirCapitals() async {
    let seams = system()
    #expect(await joined(seams, ["I have a meeting with", "Alice tomorrow"]) == "I have a meeting with Alice tomorrow")
    #expect(await joined(seams, ["we flew to", "London last week"]) == "we flew to London last week")
    #expect(await joined(seams, ["it ships on", "Monday morning"]) == "it ships on Monday morning")
    // The tagger alone, and the spell checker alone.
    #expect(scripted(names: ["Rose"]).join(["we asked", "Rose to review"]) == "we asked Rose to review")
    #expect(scripted(knows: { $0 != "keystone" }).join(["deploy it with", "Keystone"]) == "deploy it with Keystone")
}

@Test func joiningNeverWaitsForTheSpellCheckerAndAsksOncePerWord() async {
    // A spell checker that does not answer until the test lets it.
    let gate = DispatchSemaphore(value: 0)
    let asked = Mutex<[String]>([])
    let spelling = SeamSpelling(queue: DispatchQueue(label: "seams-test-spelling")) { word in
        asked.withLock { $0.append(word) }
        gate.wait()
        return true
    }
    let seams = DictationSeams(language: "en-US", terms: [], spelling: spelling, isName: { _, _ in false })
    // Each revision of a result still being recognized keeps the capital while there is no answer, and asks nothing
    // more: the question is the word's, not the result's.
    for revision in ["Pull", "Pull request", "Pull request splitting it"] {
        #expect(seams.join([.init("our big"), .init(revision, isFinal: false)]) == "our big \(revision)")
    }
    // A final result decided before the answer keeps its capital for good.
    #expect(seams.join(["we opened a", "Pull request"]) == "we opened a Pull request")
    gate.signal()
    await spelling.settled(within: .seconds(30))
    #expect(asked.withLock { $0 } == ["pull"])
    #expect(seams.join([.init("our big"), .init("Pull request", isFinal: false)]) == "our big pull request")
    #expect(seams.join(["our big", "Pull request"]) == "our big pull request")
    #expect(seams.join(["we opened a", "Pull request"]) == "we opened a Pull request")
    #expect(asked.withLock { $0 } == ["pull"])
}

@Test func eachFinalPauseIsDecidedOnceSoCommittedTextStaysAPrefix() async {
    let asked = Mutex(0)
    // Knows the word the first time it is asked, and never again (the answers of one seams' spelling are kept, so
    // only another word is asked again).
    let seams = scripted(knows: { _ in asked.withLock { count in count += 1; return count == 1 } })
    let first = seams.join(["our big", "Pull request"])
    #expect(first == "our big pull request")
    #expect(seams.join(["our big", "Pull request", "Then more"]).hasPrefix(first))
    #expect(seams.join(["our big", "Pull request", "Then more"]) == "our big pull request Then more")
    #expect(asked.withLock { $0 } == 2)

    let pieces = ["We are cleaning up our big", "Pull request splitting it", "Into parts.", "Maybe we can",
                  "Then merge it"]
    let live = system()
    let whole = await joined(live, pieces)
    #expect(whole == "We are cleaning up our big pull request splitting it into parts. Maybe we can then merge it")
    for count in 1...pieces.count {
        #expect(whole.hasPrefix(live.join(Array(pieces.prefix(count)))))
    }
}

@Test func frenchLowersAfterAPauseAndKeepsNames() async {
    let seams = system("fr-CA")
    #expect(await joined(seams, ["je pense que", "On peut le faire demain"]) == "je pense que on peut le faire demain")
    #expect(await joined(seams, ["on a parlé de la", "Nouvelle version"]) == "on a parlé de la nouvelle version")
    #expect(await joined(seams, ["on se voit avec", "Marie demain"]) == "on se voit avec Marie demain")
    #expect(await joined(seams, ["C'est fini.", "Ensuite on part"]) == "C'est fini. Ensuite on part")
    #expect(await joined(seams, ["et elle", "A fini hier"]) == "et elle a fini hier")
    #expect(scripted("fr-FR").join(["on va", "À la gare"]) == "on va à la gare")
    // French has no capital pronoun "I": "I'm" is lowered as any word the language knows.
    #expect(scripted("fr-FR").join(["et puis", "I'm"]) == "et puis i'm")
}

@Test func otherLanguagesAreJoinedAsBefore() {
    // German capitalizes nouns; the pieces are joined as the recognizer wrote them.
    #expect(scripted("de-DE").join(["wir haben den", "Plan geändert"]) == "wir haben den Plan geändert")
    #expect(scripted("de-DE").join(["und dann", "Wir gehen"]) == "und dann Wir gehen")
    #expect(scripted("es-ES").join(["y luego", "Vamos"]) == "y luego Vamos")
}

@Test func emptyWhitespaceAndPunctuationPieces() {
    let seams = scripted()
    #expect(seams.join([String]()) == "")
    #expect(seams.join(["  ", "", "\n"]) == "")
    #expect(seams.join(["  ", "we are", "", "  ", "Done soon "]) == "we are done soon")
    // A piece of punctuation alone is the text before the next pause.
    #expect(seams.join(["we left early", ".", "Then it rained"]) == "we left early . Then it rained")
    #expect(seams.join(["we left", ",", "Then it rained"]) == "we left , then it rained")
    #expect(seams.join(["we left", "…", "Then"]) == "we left … Then")
    // A piece that starts with a digit, a mark or a quote is left as it is.
    #expect(seams.join(["we need", "42 more"]) == "we need 42 more")
    #expect(seams.join(["she said", "“Maybe later”"]) == "she said “Maybe later”")
    #expect(seams.join(["and", "— Then"]) == "and — Then")
    // One letter is a letter ("plan B"), but for the article "A".
    #expect(seams.join(["it is", "A test"]) == "it is a test")
    #expect(seams.join(["we go with plan", "B instead"]) == "we go with plan B instead")
    #expect(seams.join(["run it with dash", "P"]) == "run it with dash P")
}

@Test func thePipelineJoinsBeforeFillersAndCorrections() async {
    // A learned correction keeps the capital it replaces: with the pause's capital lowered first, it writes lowercase.
    let corrections = CorrectionList(entries: [Correction(heard: "sink", meant: "sync")])
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: corrections)
    let output = await pipeline.run(segments: ["we need to", "Sink the files", "So we", "Um, maybe later."])
    #expect(output.heard == "we need to sink the files so we um, maybe later.")
    #expect(output.written == "we need to sync the files so we maybe later.")
    #expect(DictationTextPipeline.transcript(["we need to", "Sink the files"]) == "we need to Sink the files")
}
