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

/// Replies Apple's on-device model gave to made-up French dictation.
@Test func guardHandlesFrenchFixesAndRefusesTranslations() {
    #expect(AIFixGuard.check(original: "Il faut que je prévienne mon patron que le projet et en retard",
                             fixed: "Il faut que je prévienne mon patron que le projet est en retard") == .accept)
    #expect(AIFixGuard.check(original: "Je pense que ces une bonne idée de reporter la réunion",
                             fixed: "Je pense que c'est une bonne idée de reporter la réunion") == .accept)
    #expect(AIFixGuard.check(original: "Merci pour ton aide je te revaudrai sa",
                             fixed: "Merci pour ton aide, je te revaudrai ça.") == .accept)
    #expect(AIFixGuard.check(original: "Peux-tu m'envoyer le fichier quand tu auras fini",
                             fixed: "Peux-tu m'envoyer le fichier quand tu auras fini ?") == .accept)
    // A dictated request the model translated or carried out instead of fixing.
    #expect(AIFixGuard.check(original: "Est-ce que tu peux me traduire ça en anglais",
                             fixed: "Can you translate this for me into English?") == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "Tu peux me traduire ça en anglais",
                             fixed: "Can you translate this for me into English?") == .reject(.tooManyEdits))
    #expect(AIFixGuard.check(original: "Écris un courriel à Marie pour lui dire que je serai en retard",
                             fixed: "Objet : Retard prévu\n\nBonjour Marie,\n\nJe vous informe que je serai en retard.")
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
    #expect(AIFixGuard.check(original: "right. write", fixed: "write. right") == .accept)  // two substitutions, marks put
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
    // Letters only: a number keeps its value, so "word4" could not become "wort4".
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    let suffixes: [String] = (0..<30).map { index in String([alphabet[index / 26], alphabet[index % 26]]) }
    let words = suffixes.map { "word\($0)" }
    var changed = words
    // Each replacement is one letter off, so it could be a mishearing.
    for index in [3, 9, 15, 21, 27] { changed[index] = "wort\(suffixes[index])" }  // 5 edits; 20 % of 30 is 6
    #expect(AIFixGuard.check(original: words.joined(separator: " "), fixed: changed.joined(separator: " ")) == .accept)
    for index in [1, 5] { changed[index] = "wort\(suffixes[index])" }  // 7 edits
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

@Test func aChunkThatMayContinueKeepsItsEnd() {
    // Whatever the model put after the last word goes back to the chunk's own end, quotes and brackets included.
    #expect(AIFixGuard.keepingEdges(of: "are you sure", in: "Are you sure?!", isFinal: false) == "are you sure")
    #expect(AIFixGuard.keepingEdges(of: "and then", in: "And then…", isFinal: false) == "and then")
    #expect(AIFixGuard.keepingEdges(of: "wait for me,", in: "Wait for me.", isFinal: false) == "wait for me,")
    #expect(AIFixGuard.keepingEdges(of: "Is it done?", in: "Is it done?!", isFinal: false) == "Is it done?")
    #expect(AIFixGuard.keepingEdges(of: "he called it “great”", in: "He called it “great.”", isFinal: false)
        == "he called it “great”")
    #expect(AIFixGuard.keepingEdges(of: "he called it “great”", in: "He called it “great”.", isFinal: false)
        == "he called it “great”")
    #expect(AIFixGuard.keepingEdges(of: "we will ship (soon)", in: "We will ship (soon?!)", isFinal: false)
        == "we will ship (soon)")
    #expect(AIFixGuard.keepingEdges(of: "she said \"wait,\"", in: "She said \"wait.\"", isFinal: false)
        == "she said \"wait,\"")
}

@Test func theEndOfTheDictationMayChangeItsClosingMarks() {
    #expect(AIFixGuard.keepingEdges(of: "are you sure", in: "Are you sure?!", isFinal: true) == "are you sure?!")
    #expect(AIFixGuard.keepingEdges(of: "he called it “great”", in: "He called it “great.”", isFinal: true)
        == "he called it “great.”")
}

@Test func theFirstWordKeepsItsCasePastOpeningQuotesAndBrackets() {
    #expect(AIFixGuard.keepingEdges(of: "“hello there”", in: "“Hello there.”", isFinal: false) == "“hello there”")
    #expect(AIFixGuard.keepingEdges(of: "(see below)", in: "(See below.)", isFinal: false) == "(see below)")
    #expect(AIFixGuard.keepingEdges(of: "\"their here\"", in: "\"They're here.\"", isFinal: true)
        == "\"they're here.\"")
    // A capital the chunk had stays, and opening marks the model added or dropped go back to the chunk's.
    #expect(AIFixGuard.keepingEdges(of: "When a press escape", in: "when I press escape", isFinal: false)
        == "When I press escape")
    #expect(AIFixGuard.keepingEdges(of: "“hello there”", in: "hello there”", isFinal: false) == "“hello there”")
    #expect(AIFixGuard.keepingEdges(of: "“i think so”", in: "“I think so.”", isFinal: false) == "“I think so”")
}

@Test func fixerKeepsTheEdgesOfAChunkThatMayContinue() async {
    let quoted = await fixer { _, _ in "“Hello there.”" }.fix(" “hello there”", isFinal: false)
    #expect(quoted == .init(text: " “hello there”", outcome: .unchanged))
    let fixed = await fixer { _, _ in "He knew it “great.”" }.fix(" he new it “great”", isFinal: false)
    #expect(fixed == .init(text: " he knew it “great”", outcome: .fixed))
    let middle = await fixer { _, _ in "They're going to review it tomorrow." }
        .fix(" their going to review it tomorrow", isFinal: false)
    #expect(middle == .init(text: " they're going to review it tomorrow", outcome: .fixed))
    // The end of the dictation may gain a period.
    let last = await fixer { _, _ in "They're going to review it tomorrow." }
        .fix(" their going to review it tomorrow", isFinal: true)
    #expect(last == .init(text: " they're going to review it tomorrow.", outcome: .fixed))
    let period = await fixer { _, _ in "All good here." }.fix("all good here", isFinal: true)
    #expect(period == .init(text: "all good here.", outcome: .fixed))
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
    // Case-insensitive; the most recent pair comes first.
    #expect(AIFixReference.select(from: entries, for: "is Get Hub down on mac OS", budget: 1_000)
        == [entries[1], entries[0]])
    // The meant side never selects a pair: the text already has the spelling.
    #expect(AIFixReference.select(from: entries, for: "is github down", budget: 1_000).isEmpty)
    // A pair that does not fit is skipped, and a later one that fits is still taken.
    let short = Correction(heard: "get hub", meant: "GitHub")
    let long = Correction(heard: "mac os ventura beta build", meant: "macOS Ventura beta build")
    let budget = AIFixReference.estimatedTokens(short)
    #expect(AIFixReference.estimatedTokens(long) > budget)
    #expect(AIFixReference.select(from: [short, long], for: "is get hub down on mac os ventura beta build",
                                  budget: budget) == [short])
    #expect(AIFixReference.select(from: entries, for: "get hub", budget: 0).isEmpty)
}

/// The speaker's learned corrections when "windows" and "develop" became "Ubuntu" in dictation.
let taughtList = [
    Correction(heard: "Jav model", meant: "Jev model"), Correction(heard: "common free", meant: "comment-free"),
    Correction(heard: "God forbid", meant: "god forbid"), Correction(heard: "T-Mux", meant: "tmux"),
    Correction(heard: "Onobunto", meant: "on Ubuntu"), Correction(heard: "T-Max", meant: "tmux"),
    Correction(heard: "Timox sessions", meant: "tmux sessions"), Correction(heard: "Keystrokes in", meant: "keystrokes in"),
    Correction(heard: "T-Mox", meant: "tmux"), Correction(heard: "food requests", meant: "pool requests"),
    Correction(heard: "Timok's sessions", meant: "tmux sessions"), Correction(heard: "Maestra is", meant: "Maestro is"),
    Correction(heard: "a Bundo", meant: "ubuntu"), Correction(heard: "the Najer", meant: "the nudger"),
    Correction(heard: "slash QC", meant: "/qc"), Correction(heard: "slash APRS", meant: "/aprs"),
    Correction(heard: "this basement", meant: "the spaceman"), Correction(heard: "Ubundu machine", meant: "Ubuntu machine"),
    Correction(heard: "Uguntu", meant: "Ubuntu"), Correction(heard: "BitHub", meant: "GitHub"),
    Correction(heard: "death instance", meant: "dev instance"), Correction(heard: "quarter much", meant: "quota much"),
    Correction(heard: "a bunch of ubuntu", meant: "a bunch of windows"), Correction(heard: "This is", meant: "this is"),
]

@Test func referenceSelectsAPairOnlyWhereItsHeardPhraseIsSaid() {
    func selected(_ text: String) -> [String] {
        AIFixReference.select(from: taughtList, for: text, budget: 1_000).map(\.heard)
    }
    // Sharing "on", "a", "this" or a meant word ("windows") no longer brings in the Ubuntu pairs.
    #expect(selected("I tested this on Windows and then pushed it to the develop branch.").isEmpty)
    #expect(selected("Let's develop it on a Windows machine first.").isEmpty)
    #expect(selected("We should develop a plan for the windows laptop.").isEmpty)
    #expect(selected("it runs Onobunto") == ["Onobunto"])
    // The recognizer mishears the heard phrase again, a little differently.
    #expect(selected("it runs on a bundo") == ["a Bundo"])
    #expect(selected("it runs on a bundu") == ["a Bundo"])
    #expect(selected("an Ubundo machine") == ["Ubundu machine"])
    #expect(selected("attach to my timox sessions") == ["Timok's sessions", "Timox sessions"])
    // One session is not several: a pair taught for the plural is not said by the singular.
    #expect(selected("attach to my timox session").isEmpty)
    #expect(selected("open a T-Mux session") == ["T-Mox", "T-Max", "T-Mux"])
    // A real word is not a heard word misheard again: "mix" says "mix", not "Max" nor "Mux".
    #expect(selected("open a T-Mix session").isEmpty)
    // A phrase of function words only must be said as it is.
    #expect(selected("This is fine") == ["This is"])
    #expect(selected("this was fine").isEmpty)
    // Part of a heard phrase is not the phrase.
    #expect(selected("it runs bundu").isEmpty)
    #expect(selected("go to the basement").isEmpty)
    #expect(selected("type slash help").isEmpty)
    #expect(selected("a quarter of the budget").isEmpty)
    #expect(selected("I mix colors").isEmpty)
    // A match is the words that said the whole phrase, and only those.
    #expect(AIFixReference.matches(of: "a Bundo", in: "it runs on a bundu") == [3..<5])
    #expect(AIFixReference.matches(of: "This is", in: "so this is it") == [1..<3])
    #expect(AIFixReference.matches(of: "a Bundo", in: "bundu").isEmpty)
    #expect(AIFixReference.matches(of: "a Bundo", in: "use bundu").isEmpty)
}

/// Common words that sound nothing like any heard phrase the speaker taught, nor like its taught spellings.
let unrelatedWords = [
    "point", "windows", "develop", "opened", "open", "people", "number", "water", "before", "system", "program",
    "question", "problem", "house", "world", "school", "moment", "business", "money", "story", "family", "night",
    "place", "update", "button", "bottom", "bundle", "bond", "band", "bounty", "abandon", "butter", "pointer",
    "counter", "country", "account", "amount", "mountain", "contain", "content", "context", "commit", "branch",
    "merge", "deploy", "laptop", "server", "client", "build", "test", "runs", "code", "file", "folder", "table",
    "mobile", "modern", "middle", "results", "lessons", "strokes", "tax", "wax", "fax", "box", "fox", "match",
    "fund", "roof", "three", "tree", "freeze", "dog", "forget", "forward", "lunch", "punch", "distance", "slack",
    "flash", "cannon", "mister", "casement", "dead", "unto", "github", "toxic", "nature", "job", "into", "under",
]

@Test func unrelatedCommonWordsNeverMatchATaughtHeardWord() {
    for heard in taughtList.map(\.heard) {
        let phrase = AIFixGuard.words(in: heard)
        for index in phrase.indices where SpokenWords.isContent(phrase[index]) {
            for word in unrelatedWords {
                #expect(!SpokenWords.isVariant(word, of: phrase[index]), "\(word) ~ \(phrase[index])")
                var said = phrase
                said[index] = word
                let text = (["so"] + said + ["now"]).joined(separator: " ")
                #expect(AIFixReference.matches(of: heard, in: text).isEmpty, "\(text) ~ \(heard)")
            }
        }
    }
    // Nor could the model's swap of one of them for a taught spelling be a mishearing.
    for meant in ["Ubuntu", "tmux", "GitHub", "nudger", "spaceman", "Maestro", "quota"] {
        for word in unrelatedWords where word.lowercased() != meant.lowercased() {
            #expect(!SpokenWords.isClose(word, meant), "\(word) ~ \(meant)")
        }
    }
}

@Test func aRoughSoundAloneIsNotAMishearing() {
    // "point" and "Bundo" are both "pnt" roughly, but share no letter in place and start apart.
    #expect(SpokenWords.roughSound(SpokenWords.sound("point")) == SpokenWords.roughSound(SpokenWords.sound("bundo")))
    #expect(!SpokenWords.isVariant("point", of: "bundo") && !SpokenWords.isClose("point", "bundo"))
    #expect(!SpokenWords.isVariant("tax", of: "max") && SpokenWords.isVariant("mix", of: "max"))
    #expect(SpokenWords.isVariant("bundu", of: "bundo") && SpokenWords.isVariant("timox", of: "timok's"))
    let bundo = Correction(heard: "a Bundo", meant: "ubuntu")
    #expect(AIFixReference.select(from: [bundo], for: "That's the point", budget: 1_000).isEmpty)
    #expect(AIFixReference.select(from: [bundo], for: "That's a point", budget: 1_000).isEmpty)
    #expect(AIFixGuard.check(original: "That's the point", fixed: "That's the ubuntu", taught: [bundo])
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "That's a point", fixed: "That's ubuntu", taught: [bundo])
        == .reject(.implausibleSubstitution))
}

@Test func aTaughtPairCoversOnlyTheWordsThatSaidItsHeardPhrase() {
    let bundo = Correction(heard: "a Bundo", meant: "ubuntu")
    // The neighbouring word is not part of the heard phrase, said or not.
    #expect(AIFixGuard.check(original: "use Bundo", fixed: "Ubuntu Bundo", taught: [bundo])
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "use a Bundo", fixed: "Ubuntu a Bundo", taught: [bundo])
        == .reject(.implausibleSubstitution))
    // The words that said the heard phrase must become the meant phrase, give or take function words.
    #expect(AIFixGuard.check(original: "use a Bundo", fixed: "use Ubuntu Bundo", taught: [bundo])
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "use a bundu", fixed: "use Ubuntu", taught: [bundo]) == .accept)
    #expect(AIFixGuard.check(original: "use a bundu", fixed: "use a Ubuntu", taught: [bundo]) == .accept)
    #expect(AIFixGuard.check(original: "on a bundu machine", fixed: "on an Ubuntu machine", taught: [bundo])
        == .accept)
    let pool = Correction(heard: "food requests", meant: "pool requests")
    #expect(AIFixGuard.check(original: "open food requests", fixed: "open pool requests", taught: [pool]) == .accept)
    #expect(AIFixGuard.check(original: "open food requests", fixed: "open food pool", taught: [pool])
        == .reject(.implausibleSubstitution))
    // The pair's place becomes its meant phrase; nothing else may change there.
    let qc = Correction(heard: "slash QC", meant: "QC")
    #expect(AIFixGuard.check(original: "then run slash QC now", fixed: "then run QC now", taught: [qc]) == .accept)
    #expect(AIFixGuard.check(original: "then run slash QC now", fixed: "then run Ubuntu now", taught: [qc])
        == .reject(.implausibleSubstitution))
    // "the basement" is not "this basement": the pair does not teach "spaceman" there.
    let spaceman = Correction(heard: "this basement", meant: "the spaceman")
    #expect(AIFixGuard.check(original: "go to the basement", fixed: "go to the spaceman", taught: [spaceman])
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "ask this basement", fixed: "ask the spaceman", taught: [spaceman])
        == .accept)
}

@Test func aVariantDiffersOnlyInItsVowels() {
    let bull = Correction(heard: "bull request", meant: "pull request")
    // "bulk" shares a first letter with "bull" and is one letter apart, but has a "k" sound "bull" has not.
    #expect(!SpokenWords.isVariant("bulk", of: "bull") && !SpokenWords.isVariant("bullet", of: "bull"))
    #expect(AIFixReference.select(from: [bull], for: "I sent a bulk request", budget: 1_000).isEmpty)
    #expect(AIFixGuard.check(original: "I sent a bulk request", fixed: "I sent a pull request", taught: [bull])
        == .reject(.implausibleSubstitution))
    // Vowels may differ; a plural "s" may not.
    #expect(SpokenWords.isVariant("bill", of: "bull") && !SpokenWords.isVariant("bulls", of: "bull"))
    #expect(!SpokenWords.isVariant("session", of: "sessions") && !SpokenWords.isVariant("java", of: "jav"))
    #expect(AIFixReference.select(from: [bull], for: "I opened a bull requests", budget: 1_000).isEmpty)
    let file = Correction(heard: "delete file", meant: "remove the file")
    #expect(AIFixGuard.check(original: "please delete files now", fixed: "please remove the file now", taught: [file])
        != .accept)
}

@Test func wordsReplacedTogetherAreEachJudged() {
    // A long word close to its fix does not carry an unrelated one, side by side or run together.
    #expect(AIFixGuard.check(original: "internationalisation windows", fixed: "internationalization Ubuntu")
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "the internationalisation", fixed: "the internationalization Ubuntu")
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "internationalizaton windows", fixed: "internationalization windows")
        == .accept)
    // A word split or joined is still one fix.
    #expect(AIFixGuard.check(original: "add a semi colon here", fixed: "add a semicolon here") == .accept)
    // "Onobunto", capitalized mid-sentence, is a name: only its pair may spell it otherwise.
    #expect(AIFixGuard.check(original: "The build runs Onobunto.", fixed: "The build runs on Ubuntu.",
                             taught: [taughtList[4]]) == .accept)
    #expect(AIFixGuard.check(original: "The build runs Onobunto.", fixed: "The build runs on Ubuntu.")
        == .reject(.changedMeaning))
    // Nor may the model bring a name of its own.
    #expect(AIFixGuard.check(original: "The build runs onobunto.", fixed: "The build runs on Ubuntu.")
        == .reject(.changedMeaning))
    #expect(AIFixGuard.check(original: "The build runs onobunto.", fixed: "The build runs on ubuntu.") == .accept)
}

@Test func soundAndSpellingEdgesDoNotJoinUnrelatedWords() {
    // "I'll" sounds like "aisle"; the adjective "ill" does not.
    #expect(SpokenWords.isClose("I'll", "aisle") && !SpokenWords.isClose("ill", "aisle"))
    #expect(AIFixGuard.check(original: "I feel ill", fixed: "I feel aisle") == .reject(.implausibleSubstitution))
    // A "gh" after "ou" or "au" is an "f" where it is said.
    #expect(SpokenWords.sound("tough") == SpokenWords.sound("tuff") && SpokenWords.sound("laugh") == "laf")
    #expect(SpokenWords.sound("though") == SpokenWords.sound("tho") && SpokenWords.sound("caught") == "kat")
    #expect(SpokenWords.sound("laughter") == "laftar" && SpokenWords.sound("slaughter") == "slatar")
    #expect(SpokenWords.sound("draughts") == SpokenWords.sound("drafts"))
    #expect(AIFixGuard.check(original: "We heard laughter", fixed: "We heard later")
        == .reject(.implausibleSubstitution))
    #expect(!SpokenWords.isClose("tough", "toe"))
    #expect(AIFixGuard.check(original: "It was a tough injury", fixed: "It was a toe injury")
        == .reject(.implausibleSubstitution))
    // No word loses its "s": "bus" is not "buy", "news" not "new", "bulls" not "bull".
    #expect(!SpokenWords.isVariant("buy", of: "bus") && !SpokenWords.isVariant("new", of: "news"))
    #expect(!SpokenWords.isVariant("gap", of: "gas") && !SpokenWords.isVariant("clay", of: "class"))
    #expect(!SpokenWords.isVariant("bulls", of: "bull") && !SpokenWords.isVariant("session", of: "sessions"))
    let bus = Correction(heard: "bus", meant: "Buzz")
    #expect(AIFixReference.select(from: [bus], for: "I will buy it", budget: 1_000).isEmpty)
    #expect(AIFixGuard.check(original: "I will buy it", fixed: "I will Buzz it", taught: [bus])
        == .reject(.implausibleSubstitution))
}

@Test func silentAndSoftLettersOnlyWhereTheyAreSo() {
    // The "w" of "whole" and "who" is silent; that of "whopping", "whoop" and "whoosh" is not.
    #expect(SpokenWords.sound("whole") == SpokenWords.sound("hole") && SpokenWords.sound("whose") == "has")
    #expect(SpokenWords.sound("whopping") == "wapang" && SpokenWords.sound("whoop").hasPrefix("w"))
    #expect(!SpokenWords.isVariant("whopping", of: "happen"))
    let happen = Correction(heard: "happen", meant: "Happen")
    #expect(AIFixReference.select(from: [happen], for: "a whopping success", budget: 1_000).isEmpty)
    // A "g" is soft only after "d": "git" is not "jet", while "nudger" still sounds like "Najer".
    #expect(SpokenWords.sound("git") != SpokenWords.sound("jet") && SpokenWords.sound("get") == "gat")
    #expect(SpokenWords.sound("nudger") == SpokenWords.sound("najer"))
    let gitLab = Correction(heard: "git lab", meant: "GitLab")
    #expect(AIFixReference.select(from: [gitLab], for: "the jet lab opened", budget: 1_000).isEmpty)
    #expect(AIFixGuard.check(original: "the jet lab opened", fixed: "the GitLab opened", taught: [gitLab])
        == .reject(.implausibleSubstitution))
}

@Test func aFixKeepsNegationsAndWordsOfQuantity() {
    for (original, fixed) in [("I do agree", "I do not agree"), ("I do not agree", "I do agree"),
                              ("I can come", "I can't come"), ("I can't come", "I can come"),
                              ("We need tea", "We only need tea"), ("Take all the cake", "Take the cake"),
                              ("Je veux venir", "Je veux pas venir"), ("Il est toujours là", "Il est là")] {
        #expect(AIFixGuard.check(original: original, fixed: fixed) == .reject(.changedMeaning),
                "\(original) -> \(fixed)")
    }
    // The same negation said another way, and a French "ne" speech dropped, are not changes of meaning.
    #expect(AIFixGuard.check(original: "Wait here. Dont leave", fixed: "Wait here. Don't leave") == .accept)
    #expect(AIFixGuard.check(original: "I do not know", fixed: "I don't know") == .accept)
    #expect(AIFixGuard.check(original: "je sais pas", fixed: "je ne sais pas", language: "fr-FR") == .accept)
    // Only function words, hesitations and repeats may be dropped.
    #expect(AIFixGuard.check(original: "I love the red car", fixed: "I love the car")
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "go to the the store", fixed: "go to the store") == .accept)
    #expect(AIFixGuard.check(original: "go to um the store", fixed: "go to the store") == .accept)
    #expect(AIFixGuard.check(original: "go build build it now", fixed: "go build it now") == .accept)
}

@Test func onlyGlueWordsComeAndGoAndModalsStay() {
    // A negation moved to another verb: the count is the same, but "not" may not be dropped or added.
    #expect(AIFixGuard.check(original: "I do not leave but stay", fixed: "I do leave but not stay")
        == .reject(.implausibleSubstitution))
    // Modals, pronouns and auxiliaries say something: they are not added or dropped.
    for (original, fixed) in [("You should go", "You go"), ("You go", "You should go"), ("It must work", "It work"),
                              ("We may leave", "We leave"), ("They might win", "They win")] {
        #expect(AIFixGuard.check(original: original, fixed: fixed) == .reject(.changedMeaning),
                "\(original) -> \(fixed)")
        // Judged without the count of modals, the change is still not a fix.
        #expect(!AIFixGuard.plausibleReply(original: original, before: AIFixGuard.words(in: original),
                                           after: AIFixGuard.words(in: fixed), taught: []))
    }
    for (original, fixed, why) in [("I told him twice", "I told twice", AIFixGuard.Rejection.implausibleSubstitution),
                                   ("It done", "It was done", .changedMeaning)] {
        #expect(AIFixGuard.check(original: original, fixed: fixed) == .reject(why),
                "\(original) -> \(fixed)")
    }
    // Nor swapped for a close word.
    #expect(AIFixGuard.check(original: "You should go", fixed: "You could go") == .reject(.changedMeaning))
    #expect(AIFixGuard.check(original: "I'll go", fixed: "I'd go") == .reject(.changedMeaning))
    // A French modal keeps its verb when a homophone fixes its ending.
    #expect(AIFixGuard.check(original: "je peut venir", fixed: "je peux venir", language: "fr-FR") == .accept)
    // A plural "s" is not a silent ending: one file is not several.
    #expect(AIFixGuard.check(original: "ouvre le fichier", fixed: "ouvre le fichiers", language: "fr-FR") != .accept)
    // Articles, prepositions and conjunctions may come and go.
    #expect(AIFixGuard.check(original: "we went to store", fixed: "we went to the store") == .accept)
    #expect(AIFixGuard.check(original: "je parle à ami", fixed: "je parle à un ami", language: "fr-FR") == .accept)
}

@Test func negativeModalsKeepTheirModalNumbersTheirValue() {
    // "couldn't" is "not" and "could": it is not "wouldn't".
    #expect(AIFixGuard.check(original: "You couldn't go", fixed: "You wouldn't go", language: "en-US")
        == .reject(.changedMeaning))
    #expect(AIFixGuard.check(original: "You cant go", fixed: "You won't go") == .reject(.changedMeaning))
    #expect(AIFixGuard.check(original: "You can't go", fixed: "You cannot go") == .accept)
    #expect(AIFixGuard.check(original: "You can not go", fixed: "You cannot go") == .accept)
    // A number keeps its value, whatever its digits look like.
    for (original, fixed) in [("Ship 10 units", "Ship 100 units"), ("Meet at 3 pm", "Meet at 8 pm"),
                              ("Version 1 is out", "Version 2 is out")] {
        #expect(AIFixGuard.check(original: original, fixed: fixed) == .reject(.changedMeaning),
                "\(original) -> \(fixed)")
    }
    // Unless a pair said there brings it.
    let version = Correction(heard: "version to", meant: "version 2")
    #expect(AIFixGuard.check(original: "use version to now", fixed: "use version 2 now", taught: [version]) == .accept)
    #expect(AIFixGuard.check(original: "use version to now", fixed: "use version 3 now", taught: [version])
        == .reject(.changedMeaning))
}

/// Edits that change what a dictation says: who, how many, whether, which modal or quantity, which name. Each is
/// refused at its place, however close its spelling.
@Test(arguments: [
    // Pronouns and possessives.
    ("He approved it.", "She approved it."), ("Your build passed.", "Our build passed."),
    ("I will send it.", "We will send it."), ("Give it to him.", "Give it to her."),
    ("They said we won.", "They said he won."), ("Tell them now.", "Tell then now."),
    ("We told she and he.", "We told he and she."), ("Il est là.", "Elle est là."),
    ("Je viens demain.", "Tu viens demain."),
    // Numbers and number words, by position.
    ("Set width 10 height 20.", "Set width 20 height 10."), ("Ship 10 units", "Ship 100 units"),
    ("Room 12 and 21", "Room 21 and 12"), ("Set width 10 height 20.", "Set width 10 height 10."),
    ("Page one then two", "Page two then one"), ("We need ten", "We need then"),
    ("we can go then", "we can go ten"),
    // Negations added, removed or moved.
    ("I do agree", "I do not agree"), ("I do not agree", "I do agree"),
    ("I do not leave but stay", "I do leave but not stay"), ("I can come", "I can't come"),
    ("We go there", "We never go there"), ("Not now, maybe later", "Now, maybe not later"),
    ("Call me, no rush", "Call me, now rush"),
    // Modals.
    ("You should go", "You could go"), ("I'll go", "I'd go"), ("You may go", "You must go"),
    ("je peux venir", "je dois venir"),
    // Quantifiers.
    ("Delete all files", "Delete some files"), ("We only need tea", "We all need tea"),
    ("Some tests passed", "Most tests passed"), ("Run each test", "Run every test"),
    ("We saw few errors", "We saw new errors"), ("It rarely works", "It barely works"),
    ("It often fails", "It soften fails"), ("Il vient souvent", "Il vient suivant"),
    // Words spelled close but said apart, and a glue word replaced by another by dropping one and adding the other.
    ("We should increase the limit", "We should decrease the limit"), ("Please include the tests", "Please exclude the tests"),
    ("Send it to Alice", "Send it from Alice"), ("Put it in the box", "Put it at the box"),
    // One or many; the tense and person of an auxiliary, in a contraction or not.
    ("Delete the file now", "Delete the files now"), ("Delete the files now", "Delete the file now"),
    ("I don't agree", "I didn't agree"), ("It isn't ready", "It wasn't ready"), ("I do agree", "I did agree"),
    ("It is done", "It was done"), ("They were going home", "They we're going home"),
    ("He hasn't left", "He hadn't left"),
    // A pronoun spelled like an article is not dropped; a contraction is spelled out with its own auxiliary.
    ("Je le prends", "Je prends"), ("Je la vois", "Je vois"), ("Je les appelle", "Je appelle"),
    ("I know that", "I know"), ("I've finished", "I had finished"), ("We're ready", "We were ready"),
    // Another vowel is another word; so is another unit.
    ("Turn left here", "Turn lift here"), ("I hate it", "I hit it"), ("Take a note", "Take a not"),
    ("They came late", "They come late"), ("Run 5 km today", "Run 5 cm today"), ("Wait 10 ms", "Wait 10 mm"),
    ("Please enable it", "Please unable it"), ("Draw a line now", "Draw alone now"), ("We work alone", "We work a line"),
    // A prefix that says the opposite.
    ("This is intended today", "This is unintended today"), ("Please install it", "Please uninstall it"),
    ("We agree", "We disagree"), ("The car is insured", "The car is uninsured"),
    ("Ce projet est connu", "Ce projet est inconnu"),
    // A leading zero counts: a code is not a number said.
    ("Use code 021 now", "Use code twenty one now"),
    // Names, but for their case.
    ("Ask Mary about it", "Ask Marie about it"), ("Send it to Bob and Alice", "Send it to Alice and Bob"),
    ("Deploy to Windows now", "Deploy to Ubuntu now"), ("Ping John today", "Ping Joan today"),
    ("GitHub is down.", "GitLab is down."), ("then open the get hub page", "then open the GitHub page"),
    // Names that start a sentence or the chunk.
    ("Mary called.", "Marie called."), ("John left early", "Joan left early"), ("Wait. Mary called", "Wait. Marie called"),
    // Units and abbreviations are not hesitations.
    ("Set the width to 10 mm", "Set the width to 10"), ("Take her to the ER now", "Take her to the now"),
    // Compound numbers keep their value; numbers said one after another are not one.
    ("Set it to twenty one", "Set it to 22"), ("Dial one two", "Dial 12"), ("Pick one hundred five", "Pick 150"),
    // An apostrophe put back does not bring a modal.
    ("Well go now", "We'll go now"),
])
func aFixThatChangesMeaningIsRefused(original: String, fixed: String) {
    let verdict = AIFixGuard.check(original: original, fixed: fixed, protecting: taughtList, taught: taughtList)
    #expect(verdict != .accept && verdict != .unchanged, "\(original) -> \(fixed)")
    // Without the taught list, it is still refused.
    #expect(AIFixGuard.check(original: original, fixed: fixed) != .accept, "\(original) -> \(fixed)")
}

/// Mishearings fixed: close words, listed homophones (pronouns and numbers too), taught pairs where they were said,
/// glue words, stutters, case and punctuation.
@Test(arguments: [
    ("When a press escape they don't disappear.", "When I press escape, they don't disappear."),
    ("I would like to by a new pear of shoes for the whether this weekend.",
     "I would like to buy a new pair of shoes for the weather this weekend."),
    ("Number won is done.", "Number one is done."), ("Please right it down.", "Please write it down."),
    ("I went their. Then we left", "I went there. Then we left"), ("Your right about that", "You're right about that"),
    ("Its broken again", "It's broken again"), ("See you in an our.", "See you in an hour."),
    ("I think ewe are right.", "I think you are right."), ("I eight lunch early.", "I ate lunch early."),
    ("The build runs Onobunto.", "The build runs on Ubuntu."),
    ("It runs on a bundu machine.", "It runs on an Ubuntu machine."),
    ("Open the food requests on GitHub.", "Open the pool requests on GitHub."),
    ("I do not know", "I don't know"), ("You can not go", "You cannot go"),
    ("Wait here. Dont leave", "Wait here. Don't leave"),
    ("Set width ten height 20.", "Set width 10 height 20."), ("we went to store", "we went to the store"),
    ("I I think so", "I think so"), ("use windows now", "use Windows now"), ("meet me there", "Meet me there."),
    ("Merci pour ton aide je te revaudrai sa", "Merci pour ton aide, je te revaudrai ça."),
    ("Je pense que ces une bonne idée", "Je pense que c'est une bonne idée"),
    ("go to um the store", "go to the store"), ("Set it to twenty one", "Set it to 21"),
    ("Pick one hundred and five", "Pick 105"), ("Room 21 please", "Room twenty one please"),
    ("Jai fini", "J'ai fini"), ("Quil arrive demain", "Qu'il arrive demain"),
    ("Set it to twenty-one", "Set it to 21"), ("I've finished", "I have finished"), ("We're ready", "We are ready"),
    ("I'm ready", "I am ready"), ("It's done", "It is done"), ("I won't go", "I will not go"),
])
func aMishearingIsFixed(original: String, fixed: String) {
    #expect(AIFixGuard.check(original: original, fixed: fixed, protecting: taughtList, taught: taughtList) == .accept,
            "\(original) -> \(fixed)")
}

/// A real word replaced by another real word that is not a listed homophone says something else, however close
/// they sound: one tense, number, vowel or preposition for another. No taught pair was said there.
@Test(arguments: [
    ("Clean the tooth now", "Clean the teeth now"), ("The goose is loose", "The geese is loose"),
    ("We want it", "We wanted it"), ("We need it", "We needed it"), ("We start it", "We started it"),
    ("We should increase the limit", "We should decrease the limit"), ("Turn left here", "Turn lift here"),
    ("Use the bat now", "Use the bit now"), ("Fill in the form now", "Fill in the from now"),
    ("It came from Paris", "It came form Paris"), ("He cold it", "He called it"),
    ("Open the food requests", "Open the pool requests"), ("Let's develop it on Windows", "Let's develop it on Ubuntu"),
    ("I sent a bulk request", "I sent a pull request"), ("Please install it", "Please uninstall it"),
])
func aRealWordIsNotSwappedForAnother(original: String, fixed: String) {
    #expect(AIFixGuard.check(original: original, fixed: fixed, language: "en-US") != .accept, "\(original) -> \(fixed)")
    #expect(AIFixGuard.check(original: original, fixed: fixed) != .accept, "\(original) -> \(fixed)")
}

/// What the dictionary-word rule lets through: a word the language does not know replaced by a close one, a taught
/// pair where its heard phrase was said, a listed homophone, and spelling, spacing or numbers written another way.
@Test(arguments: [
    // Words the language does not know.
    ("open a timux session", "open a tmux session"), ("it runs onobunto", "it runs on ubuntu"),
    ("it runs on a bundu", "it runs on ubuntu"), ("fix the wordz", "fix the words"),
    // Taught pairs (the speaker's list): "Onobunto" and "Uguntu" start with a capital, so only their pair fixes them.
    ("The build runs Onobunto.", "The build runs on Ubuntu."), ("The server runs Uguntu.", "The server runs Ubuntu."),
    ("Open the food requests on GitHub.", "Open the pool requests on GitHub."),
    // Homophones.
    ("Number won is done.", "Number one is done."), ("Please right it down.", "Please write it down."),
    ("I went their yesterday", "I went there yesterday"), ("I would like to by it", "I would like to buy it"),
    // Case, apostrophes, spacing and numbers.
    ("Its done", "It's done"), ("a semi colon", "a semicolon"), ("Set width ten height 20.", "Set width 10 height 20."),
])
func aMishearingOfANonWordOrAHomophoneIsFixed(original: String, fixed: String) {
    #expect(AIFixGuard.check(original: original, fixed: fixed, protecting: taughtList, taught: taughtList,
                             language: "en-US") == .accept, "\(original) -> \(fixed)")
}

@Test(arguments: [
    ("Il prend ces affaires", "Il prend ses affaires"), ("Il est a Paris", "Il est à Paris"),
    ("Je pense que ces une bonne idée", "Je pense que c'est une bonne idée"), ("je peut venir", "je peux venir"),
    ("chambre quatre-vingt-dix-huit", "chambre 98"), ("il a dix-sept ans", "il a 17 ans"),
])
func aFrenchHomophoneOrNumberIsFixed(original: String, fixed: String) {
    #expect(AIFixGuard.check(original: original, fixed: fixed, language: "fr-FR") == .accept, "\(original) -> \(fixed)")
}

@Test func aTaughtPairMatchesARealWordOnlyAsItIs() {
    // A fuzzy match needs a word the language does not know: "bat" is a word, so "bit -> byte" is not said there.
    let byte = Correction(heard: "bit", meant: "byte")
    #expect(AIFixReference.matches(of: "bit", in: "Use the bat now", language: "en-US").isEmpty)
    #expect(AIFixReference.select(from: [byte], for: "Use the bat now", budget: 1_000, language: "en-US").isEmpty)
    #expect(AIFixGuard.check(original: "Use the bat now", fixed: "Use the byte now", taught: [byte], language: "en-US")
        != .accept)
    // Said as it is, the pair applies.
    #expect(AIFixGuard.check(original: "Use the bit now", fixed: "Use the byte now", taught: [byte], language: "en-US")
        == .accept)
    // A word the language does not know still matches a heard word misheard again ("a bundu" for "a Bundo").
    #expect(AIFixReference.matches(of: "a Bundo", in: "it runs on a bundu", language: "en-US") == [3..<5])
    let pool = Correction(heard: "food requests", meant: "pool requests")
    #expect(AIFixReference.matches(of: "food requests", in: "open the good requests", language: "en-US").isEmpty)
    #expect(AIFixReference.matches(of: "food requests", in: "open the fuud requests", language: "en-US") == [2..<4])
    #expect(AIFixGuard.check(original: "open the good requests", fixed: "open the pool requests", taught: [pool],
                             language: "en-US") != .accept)
}

@Test func theLexiconKnowsTheLanguagesWordsNamesAndTaughtSpellings() {
    let english = Lexicon(language: "en-US", taught: ["the nudger", "Jev model"])
    for word in ["bat", "teeth", "wanted", "windows", "ubuntu", "mary", "don't", "10", "jev"] {
        #expect(english.isWord(word), "\(word)")
    }
    for word in ["bundu", "onobunto", "uguntu", "timux", "wordz"] { #expect(!english.isWord(word), "\(word)") }
    let french = Lexicon(language: "fr-FR")
    #expect(french.isWord("c'est") && french.isWord("peux") && !french.isWord("bundu"))
    // Without a dictionary for the language, every word is real: only homophones and taught pairs change words.
    #expect(SystemSpelling.dictionaries(for: "zz-ZZ") == nil && SystemSpelling.dictionaries(for: "en-US") != nil)
    #expect(Lexicon(language: "zz-ZZ").isWord("bundu"))
    let fake = Lexicon(lookup: { _ in false })
    #expect(!fake.isWord("bat") && fake.isWord("3pm"))
    #expect(AIFixGuard.check(original: "it runs onobunto", fixed: "it runs on ubuntu", language: "en-US",
                             lexicon: Lexicon(lookup: { _ in true })) != .accept)
    #expect(AIFixGuard.check(original: "it runs onobunto", fixed: "it runs on ubuntu", language: "en-US",
                             lexicon: fake) == .accept)
}

@Test func taughtPairsApplyBeforeTheLimitsAndMeaningCounts() {
    // A pair whose heard phrase holds a word of quantity: the reply is judged with the pair applied.
    let allstate = Correction(heard: "all state", meant: "Allstate")
    #expect(AIFixGuard.check(original: "I called all stayt today", fixed: "I called Allstate today",
                             taught: [allstate]) == .accept)
    #expect(AIFixGuard.check(original: "I called all stayt today", fixed: "I called Allstate today")
        == .reject(.changedMeaning))
    // A pair may add more words than the limit lets a reply add by itself.
    let server = Correction(heard: "server", meant: "production web server")
    #expect(AIFixGuard.check(original: "open server now", fixed: "open production web server now", taught: [server])
        == .accept)
    #expect(AIFixGuard.check(original: "open server now", fixed: "open production web server now")
        == .reject(.wordCountChanged))
    #expect(AIFixGuard.check(original: "open server now", fixed: "open staging web server now", taught: [server])
        == .reject(.wordCountChanged))
    // French numbers said in several words.
    #expect(SpokenWords.numberValue(["quatre", "vingt", "dix"], language: "fr-FR") == 90)
    #expect(SpokenWords.numberValue(["vingt", "et", "un"], language: "fr-FR") == 21)
    #expect(SpokenWords.numberValue(["two", "thousand", "twenty", "six"], language: "en-US") == 2026)
    #expect(SpokenWords.numberValue(["ten", "twenty"], language: "en-US") == nil)
    #expect(AIFixGuard.check(original: "chambre vingt et un", fixed: "chambre 21", language: "fr-FR") == .accept)
    #expect(AIFixGuard.check(original: "chambre quatre-vingt-dix", fixed: "chambre 90", language: "fr-FR") == .accept)
    // Seventeen to nineteen are said as ten and a unit, alone or after sixty and eighty.
    for (said, value) in [("quatre-vingt-dix-huit", 98), ("dix-sept", 17), ("soixante-dix-neuf", 79),
                          ("quatre-vingt-dix-sept", 97), ("cent dix-huit", 118), ("soixante et onze", 71)] {
        #expect(SpokenWords.numberValue(AIFixGuard.words(in: said.replacingOccurrences(of: "-", with: " ")),
                                        language: "fr-FR") == value, "\(said)")
    }
    #expect(AIFixGuard.check(original: "chambre quatre-vingt-dix-huit", fixed: "chambre 98", language: "fr-FR")
        == .accept)
    #expect(AIFixGuard.check(original: "chambre quatre-vingt-dix-huit", fixed: "chambre 99", language: "fr-FR")
        != .accept)
    // Only "dix" takes a unit after it: "onze sept" and "ten seven" are two numbers.
    #expect(SpokenWords.numberValue(["onze", "sept"], language: "fr-FR") == nil)
    #expect(SpokenWords.numberValue(["ten", "seven"], language: "en-US") == nil)
    #expect(SpokenWords.numberValue(["dix", "deux"], language: "fr-FR") == nil)
    #expect(AIFixGuard.check(original: "pages 1-2", fixed: "pages 1 2") == .reject(.changedStructure))
    // A heard word is not said by its opposite: "unable" is a real word, so a pair taught for "enable" does not
    // replace it.
    #expect(AIFixReference.matches(of: "enable", in: "unable").isEmpty)
    #expect(AIFixReference.matches(of: "install", in: "uninstall").isEmpty)
    let enable = Correction(heard: "enable to access", meant: "able to access")
    #expect(AIFixReference.select(from: [enable], for: "Users are unable to access files", budget: 1_000).isEmpty)
    #expect(AIFixGuard.check(original: "Users are unable to access files", fixed: "Users are able to access files",
                             taught: [enable]) != .accept)
}

@Test func aTaughtPairBringsItsMarksWhereItWasSaid() {
    let commentFree = Correction(heard: "common free", meant: "comment-free")
    #expect(AIFixGuard.check(original: "type comin free now", fixed: "type comment-free now", taught: [commentFree])
        == .accept)
    #expect(AIFixGuard.check(original: "then run slash QC now", fixed: "then run /qc now", taught: [taughtList[14]])
        == .accept)
    // Without the pair, or elsewhere than where it was said, the mark is a change of structure.
    #expect(AIFixGuard.check(original: "type comin free now", fixed: "type comment-free now")
        == .reject(.changedStructure))
    #expect(AIFixGuard.check(original: "type comin free now", fixed: "type-comment free now", taught: [commentFree])
        == .reject(.changedStructure))
    // A dash between clauses ends a phrase.
    let pool = Correction(heard: "food requests", meant: "pool requests")
    #expect(AIFixReference.matches(of: "food requests", in: "I ordered food — requests are pending").isEmpty)
    #expect(AIFixReference.matches(of: "food requests", in: "I ordered food – requests are pending").isEmpty)
    #expect(AIFixGuard.check(original: "I ordered food — requests are pending",
                             fixed: "I ordered pool — requests are pending", taught: [pool])
        == .reject(.implausibleSubstitution))
}

@Test func namesAndMeaningsAreFoundWordByWord() {
    #expect(AIFixGuard.names(in: "ask Mary. Then use GitHub, I think")
        == [false, true, false, false, true, false, false])
    #expect(AIFixGuard.names(in: "Ubuntu machine", midSentence: true) == [true, false])
    // At a sentence start, any capitalized word may be a name but function words, short words and guarded ones.
    #expect(AIFixGuard.names(in: "Mary called. The end. So. Dont go. Ten") == [true, false, false, false, false, false,
                                                                              false, false])
    #expect(SpokenWords.meaning(of: "his", language: "en-US").person == "he"
        && SpokenWords.meaning(of: "he's", language: nil).person == "he")
    #expect(SpokenWords.meaning(of: "ten", language: "en-US").number == "10")
    #expect(SpokenWords.meaning(of: "couldn't", language: "en-US").strict == ["not", "could"])
    // French pronouns are found past an apostrophe; an English contraction's "t" is not "tu".
    #expect(SpokenWords.meaning(of: "j'ai", language: "fr-FR").person == "je")
    #expect(SpokenWords.meaning(of: "qu'il", language: "fr-FR").person == "il")
    #expect(SpokenWords.meaning(of: "don't", language: nil).person == nil)
}

@Test func aPairMayAddWordsAtTheEdgesOfItsHeardPhrase() {
    let prefix = Correction(heard: "server", meant: "production server")
    #expect(AIFixGuard.check(original: "open server now", fixed: "open production server now", taught: [prefix])
        == .accept)
    let suffix = Correction(heard: "server", meant: "server production")
    #expect(AIFixGuard.check(original: "open server now", fixed: "open server production now", taught: [suffix])
        == .accept)
    // Without the pair, or with another word added, it is not a fix.
    #expect(AIFixGuard.check(original: "open server now", fixed: "open production server now")
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "open server now", fixed: "open staging server now", taught: [prefix])
        == .reject(.implausibleSubstitution))
}

@Test func homophonesAreThoseOfTheLanguageDictated() {
    // "sang" and "sent" are French homophones, not English ones.
    #expect(AIFixGuard.check(original: "I sang it", fixed: "I sent it", language: "en-US")
        == .reject(.implausibleSubstitution))
    #expect(!SpokenWords.isClose("sang", "sent", language: "en-US"))
    #expect(SpokenWords.isClose("sang", "sent", language: "fr-FR") && SpokenWords.isClose("won", "one", language: "en"))
    #expect(!SpokenWords.isClose("won", "one", language: "fr-FR"))
    #expect(SpokenWords.isVariant("vert", of: "verre", language: "fr-FR")
        && !SpokenWords.isVariant("vert", of: "verre", language: "en-US"))
}

@Test func chIsNotSh() {
    #expect(SpokenWords.sound("child") == "Cald" && SpokenWords.sound("should") == "Xald")
    #expect(!SpokenWords.isVariant("should", of: "child"))
    let childcare = Correction(heard: "child care", meant: "childcare")
    #expect(AIFixReference.select(from: [childcare], for: "You should care", budget: 1_000).isEmpty)
    #expect(AIFixGuard.check(original: "You should care", fixed: "You childcare", taught: [childcare])
        == .reject(.changedMeaning))
    #expect(!SpokenWords.isVariant("shield", of: "child"))
    #expect(AIFixReference.select(from: [childcare], for: "the shield care", budget: 1_000).isEmpty)
    // "ch" is a "k" in "chr", "chl" and "sch"; "tch" is "ch".
    #expect(SpokenWords.sound("chrome") == SpokenWords.sound("krome") && SpokenWords.sound("school") == "skal")
    #expect(SpokenWords.sound("witch") == SpokenWords.sound("which"))
}

@Test func functionWordsAreThoseOfTheLanguageDictated() {
    // The French "son" is an English content word.
    #expect(SpokenWords.isContent("son", language: "en-US") && !SpokenWords.isContent("son", language: "fr_CA"))
    #expect(!SpokenWords.isContent("son") && !SpokenWords.isContent("the", language: "en-US"))
    let son = Correction(heard: "son called", meant: "Sean called")
    #expect(AIFixReference.select(from: [son], for: "my sonn called", budget: 1_000, language: "en-US") == [son])
    #expect(AIFixReference.select(from: [son], for: "my sonn called", budget: 1_000, language: "fr-FR").isEmpty)
    let taught = CorrectionList(entries: [Correction(heard: "sun", meant: "son")])
    #expect(taught.vocabulary(language: "en-GB") == ["son"])
    #expect(taught.vocabulary(language: "fr-FR").isEmpty && taught.vocabulary.isEmpty)
}

@Test func theGuardStopsTryingTaughtPlacesWhenCancelled() async {
    let pool = Correction(heard: "food requests", meant: "pool requests")
    #expect(AIFixGuard.check(original: "their food requests", fixed: "there pool requests", taught: [pool]) == .accept)
    let cancelled = Task { () -> AIFixGuard.Verdict in
        while !Task.isCancelled { await Task.yield() }
        return AIFixGuard.check(original: "their food requests", fixed: "there pool requests", taught: [pool])
    }
    cancelled.cancel()
    #expect(await cancelled.value == .reject(.implausibleSubstitution))
}

@Test func aTaughtPairAndANeighbouringFixAreJudgedApart() {
    let pool = Correction(heard: "food requests", meant: "pool requests")
    // One stretch of changes, "their food" -> "there pool": "there" is close to "their", and the pair fixes the rest.
    #expect(AIFixGuard.check(original: "their food requests", fixed: "there pool requests", taught: [pool]) == .accept)
    #expect(AIFixGuard.check(original: "open their food requests", fixed: "open there pool requests",
                             taught: [pool]) == .accept)
    // The neighbour must still be a mishearing of its own.
    #expect(AIFixGuard.check(original: "windows food requests", fixed: "ubuntu pool requests", taught: [pool])
        == .reject(.implausibleSubstitution))
    // A place the reply left alone is not applied: the other place's fix stands by itself.
    #expect(AIFixGuard.check(original: "food requests and their food requests",
                             fixed: "food requests and there pool requests", taught: [pool]) == .accept)
}

@Test func aHeardPhraseIsNotSaidAcrossTheEndOfASentence() {
    let bull = Correction(heard: "bull request", meant: "pull request")
    #expect(AIFixReference.matches(of: "bull request", in: "Watch the bull. Request access.").isEmpty)
    #expect(AIFixReference.matches(of: "bull request", in: "Open the bull request (now)") == [2..<4])
    #expect(AIFixReference.select(from: [bull], for: "Watch the bull. Request access.", budget: 1_000).isEmpty)
    // Nor does the guard let the pair's spelling in there.
    let pool = Correction(heard: "food requests", meant: "pool requests")
    #expect(AIFixGuard.check(original: "Get some food. Requests later.", fixed: "Get some pool. Requests later.",
                             taught: [pool]) == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "Get some food; requests later.", fixed: "Get some pool; requests later.",
                             taught: [pool]) == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "Get some food requests later.", fixed: "Get some pool requests later.",
                             taught: [pool]) == .accept)
    // A comma, hyphen or slash does not end a phrase: "T-Mux" is one.
    #expect(AIFixReference.matches(of: "T-Mux", in: "open T-Mux now") == [1..<3])
    #expect(AIFixReference.matches(of: "bull request", in: "a bull, request") == [1..<3])
    // A heard phrase with a mark of its own is said with that mark.
    #expect(AIFixReference.matches(of: "node. js", in: "use node. js here") == [1..<3])
    #expect(AIFixReference.matches(of: "node. js", in: "use node js here").isEmpty)
    // The same mark: a semicolon is not the heard phrase's period; a typographic quote is a plain one.
    #expect(AIFixReference.matches(of: "bull. request", in: "the bull; request").isEmpty)
    #expect(AIFixReference.matches(of: "bull. request", in: "the bull. request") == [1..<3])
    #expect(AIFixReference.matches(of: "say \"hi", in: "we say “hi") == [1..<3])
    // Marks at the edges of a heard phrase must be there too.
    #expect(AIFixReference.matches(of: "bull.", in: "a bull request").isEmpty)
    #expect(AIFixReference.matches(of: "bull.", in: "a bull. Request") == [1..<2])
    #expect(AIFixReference.matches(of: "(bull", in: "a bull request").isEmpty)
    #expect(AIFixReference.matches(of: "(bull", in: "a (bull request") == [1..<2])
    let food = Correction(heard: "food.", meant: "pool.")
    #expect(AIFixGuard.check(original: "a food request", fixed: "a pool request", taught: [food])
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "Get the food. Then go", fixed: "Get the pool. Then go", taught: [food])
        == .accept)
    let period = Correction(heard: "food. requests", meant: "pool. requests")
    #expect(AIFixGuard.check(original: "Get some food; requests later.", fixed: "Get some pool; requests later.",
                             taught: [period]) == .reject(.implausibleSubstitution))
}

@Test func referenceSelectionScalesWithDistinctWordsAndStopsWhenCancelled() async {
    // Thousands of pairs that share few words: each text word is compared with each distinct heard word once.
    let many = (0..<3_000).map { Correction(heard: "zork\($0) blip\($0 % 7)", meant: "Zork \($0)") }
    let bull = Correction(heard: "bull request", meant: "pull request")
    let text = Array(repeating: "I opened a bull request for the zork12 blip5 build.", count: 50).joined(separator: " ")
    #expect(AIFixReference.select(from: many + [bull], for: text, budget: 1_000) == [bull, many[12]])
    // The fixer's time limit cancels its task; a cancelled selection stops.
    let cancelled = Task { () -> [Correction] in
        while !Task.isCancelled { await Task.yield() }
        return AIFixReference.select(from: many + [bull], for: text, budget: 1_000)
    }
    cancelled.cancel()
    #expect(await cancelled.value.isEmpty)
}

@Test func homophonesSpelledApartAreMishearings() {
    for (heard, meant) in [("won", "one"), ("you", "ewe"), ("ate", "eight"), ("knight", "night"),
                           ("write", "right"), ("wright", "right"), ("our", "hour"), ("whole", "hole"),
                           ("which", "witch"), ("wait", "weight"), ("threw", "through"), ("know", "no"),
                           ("knew", "new"), ("gnu", "new"), ("flour", "flower"), ("aloud", "allowed"),
                           ("heir", "air"), ("two", "too"), ("wood", "would"), ("pseudo", "sudo"),
                           ("eye", "I"), ("bye", "buy"), ("whose", "who's"), ("scene", "seen"), ("rain", "reign"),
                           ("Najer", "nudger"), ("vert", "verre"), ("sans", "cent")] {
        #expect(SpokenWords.isClose(heard, meant), "\(heard) -> \(meant)")
        #expect(SpokenWords.isClose(meant, heard), "\(meant) -> \(heard)")
    }
    // The model's repair of one passes the guard.
    for (original, fixed) in [("Number won is done.", "Number one is done."),
                              ("I eight lunch early.", "I ate lunch early."),
                              ("The night rode in.", "The knight rode in."),
                              ("Please right it down.", "Please write it down."),
                              ("See you in an our.", "See you in an hour."),
                              ("I think ewe are right.", "I think you are right.")] {
        #expect(AIFixGuard.check(original: original, fixed: fixed) == .accept, "\(original) -> \(fixed)")
    }
    // While words that only share a rough sound stay apart.
    for (heard, meant) in [("point", "Bundo"), ("point", "Ubuntu"), ("opened", "Ubuntu"), ("use", "Ubuntu"),
                           ("windows", "Ubuntu"), ("develop", "Ubuntu"), ("count", "Uguntu"), ("behind", "band")] {
        #expect(!SpokenWords.isClose(heard, meant), "\(heard) -> \(meant)")
    }
}

@Test func mishearingsAreCloseAndUnrelatedWordsAreNot() {
    for (heard, meant) in [("their", "there"), ("pear", "pair"), ("by", "buy"), ("whether", "weather"),
                           ("cold", "called"), ("bull", "pull"), ("a", "I"), ("ces", "c'est"), ("sa", "ça"),
                           ("et", "est"), ("Onobunto", "on Ubuntu"), ("abundo", "ubuntu"), ("GitHub", "github")] {
        #expect(SpokenWords.isClose(heard, meant), "\(heard) -> \(meant)")
    }
    for (heard, meant) in [("windows", "Ubuntu"), ("develop", "Ubuntu"), ("count", "Uguntu"), ("food", "pool"),
                           ("laptop", "Ubuntu"), ("fool", "bar"), ("increase", "decrease"), ("include", "exclude"),
                           ("to", "from"), ("x", "y")] {
        #expect(!SpokenWords.isClose(heard, meant), "\(heard) -> \(meant)")
    }
    #expect(!SpokenWords.isContent("the") && !SpokenWords.isContent("a") && !SpokenWords.isContent("qc"))
    #expect(!SpokenWords.isContent("dans") && !SpokenWords.isContent("C’est"))
    #expect(SpokenWords.isContent("Ubuntu") && SpokenWords.isContent("develop"))
}

@Test func guardRefusesAWordSwappedInThatWasNotMisheard() {
    // The replies Apple's on-device model gave with the Ubuntu pairs listed.
    let listed = [taughtList[22], taughtList[17], taughtList[12], taughtList[4]]
    #expect(AIFixGuard.check(original: "Let's develop it on a Windows machine first.",
                             fixed: "Let's develop it on a Ubuntu machine first.", protecting: taughtList,
                             taught: listed) == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "We should develop a plan for the windows laptop.",
                             fixed: "We should develop a plan for the ubuntu laptop.", protecting: taughtList,
                             taught: listed) == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "Let's develop it on a Windows machine first.",
                             fixed: "Let's Ubuntu it on a Windows machine first.", protecting: taughtList,
                             taught: listed) == .reject(.implausibleSubstitution))
    // An added word other than a function word is not a fix either.
    #expect(AIFixGuard.check(original: "it runs on a Windows machine", fixed: "it runs on a Ubuntu Windows machine")
        == .reject(.implausibleSubstitution))
    // Close words pass without being taught; a taught pair passes where its heard phrase was said.
    #expect(AIFixGuard.check(original: "I went their. Then we left", fixed: "I went there. Then we left") == .accept)
    #expect(AIFixGuard.check(original: "The build runs Onobunto.", fixed: "The build runs on Ubuntu.",
                             protecting: taughtList, taught: [taughtList[4]]) == .accept)
    #expect(AIFixGuard.check(original: "open food requests", fixed: "open pool requests")
        == .reject(.implausibleSubstitution))
    #expect(AIFixGuard.check(original: "open food requests", fixed: "open pool requests", taught: [taughtList[9]])
        == .accept)
    // The taught pair covers only where its heard phrase was said.
    #expect(AIFixGuard.check(original: "go ask the Najer about windows", fixed: "go ask the Najer about nudger",
                             taught: [taughtList[13]]) == .reject(.implausibleSubstitution))
    // Function words may come and go around a fix.
    #expect(AIFixGuard.check(original: "we went to store", fixed: "we went to the store") == .accept)
}

@Test func fixerRefusesAnUnrelatedTaughtSpelling() async {
    let corrections = CorrectionList(entries: taughtList)
    let seen = Mutex("")
    let result = await fixer(corrections: corrections) { instructions, _ in
        seen.withLock { $0 = instructions }
        return "Let's develop it on a Ubuntu machine first."
    }.fix("Let's develop it on a Windows machine first.", isFinal: true)
    #expect(result == .init(text: "Let's develop it on a Windows machine first.", outcome: .rejected,
                            rejection: .implausibleSubstitution))
    #expect(seen.withLock { $0 } == TranscriptFixer.baseInstructions)
    let taught = await fixer(corrections: corrections) { _, _ in "The build runs on Ubuntu." }
        .fix("The build runs Onobunto.", isFinal: true)
    #expect(taught == .init(text: "The build runs on Ubuntu.", outcome: .fixed))
}

@Test func hunksAreTheStretchesThatDiffer() {
    let hunks = AIFixGuard.hunks(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"])
    #expect(hunks.map(\.old) == [1..<2, 4..<4] && hunks.map(\.new) == [1..<2, 4..<5])
    // A substitution is preferred over a removal and an addition.
    #expect(AIFixGuard.hunks(["bat", "bar"], ["bar", "bar"]).map(\.old) == [0..<1])
    #expect(AIFixGuard.hunks(["a", "semi", "colon"], ["a", "semicolon"]).map(\.old) == [1..<3])
    #expect(AIFixGuard.hunks(["same"], ["same"]).isEmpty)
}

@Test func instructionsListTheReferencePairs() {
    let text = TranscriptFixer.instructions(reference: [Correction(heard: "get hub", meant: "GitHub")])
    #expect(text.contains("get hub -> GitHub"))
    #expect(TranscriptFixer.instructions(reference: []) == TranscriptFixer.baseInstructions)
    #expect(TranscriptFixer.baseInstructions.contains("never translate"))
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

@Test func fixerListsLearnedCorrectionsAndKeepsTheWordsTheyProduced() async {
    let corrections = CorrectionList(entries: [Correction(heard: "get hub", meant: "GitHub")])
    let seenInstructions = Mutex("")
    let fix = fixer(corrections: corrections) { instructions, _ in
        seenInstructions.withLock { $0 = instructions }
        return "I opened a pull request on get hub"
    }
    // The model undid a learned correction: the reply is refused, not corrected again.
    let result = await fix.fix("I opened a bull request on GitHub", isFinal: false)
    #expect(result == .init(text: "I opened a bull request on GitHub", outcome: .rejected,
                            rejection: .changedCorrection))
    // The chunk has the meant spelling, not the heard one, so the pair was not listed.
    #expect(seenInstructions.withLock { $0 } == TranscriptFixer.baseInstructions)
    // Other words may still be fixed around it.
    let kept = await fixer(corrections: corrections) { _, _ in "I opened a pull request on GitHub" }
        .fix("I opened a bul request on GitHub", isFinal: false)
    #expect(kept == .init(text: "I opened a pull request on GitHub", outcome: .fixed))
    // Where the heard phrase is said, the pair is listed and the model may apply it.
    let listed = await fixer(corrections: corrections) { instructions, _ in
        seenInstructions.withLock { $0 = instructions }
        return "I opened a pull request on GitHub"
    }.fix("I opened a pull request on get hub", isFinal: false)
    #expect(listed == .init(text: "I opened a pull request on GitHub", outcome: .fixed))
    #expect(seenInstructions.withLock { $0 }.contains("get hub -> GitHub"))
}

@Test func fixerNeverRewritesACorrectedWordThroughAChain() async {
    // "foo" was already corrected to "bar" before the chunk reached the fixer.
    let chain = CorrectionList(entries: [Correction(heard: "foo", meant: "bar"), Correction(heard: "bar", meant: "baz")])
    let chained = await fixer(corrections: chain) { _, _ in "I said baz" }.fix("I said bar", isFinal: true)
    #expect(chained == .init(text: "I said bar", outcome: .rejected, rejection: .changedCorrection))
    let punctuated = await fixer(corrections: chain) { _, _ in "I said bar, then left." }
        .fix("I said bar then left", isFinal: true)
    #expect(punctuated == .init(text: "I said bar, then left.", outcome: .fixed))
    // The model's own words are not run through the rules again: a word it shifted keeps its spelling, and one it
    // introduced stays as the model wrote it.
    let shifted = await fixer(corrections: chain) { _, _ in "bar is open now to" }
        .fix("the bar is open now", isFinal: false)
    #expect(shifted == .init(text: "bar is open now to", outcome: .fixed))
    let twin = await fixer(corrections: chain) { _, _ in "bar bar" }.fix("bahr bar", isFinal: true)
    #expect(twin == .init(text: "bar bar", outcome: .fixed))
}

@Test func guardProtectsEveryOccurrenceOfAMeantPhrase() {
    let corrections = [Correction(heard: "bull request", meant: "pull request")]
    #expect(AIFixGuard.check(original: "a pull request and a pull request", fixed: "a pull request and a full request",
                             protecting: corrections) == .reject(.changedCorrection))
    #expect(AIFixGuard.check(original: "a pull request and a bul", fixed: "a pull request and a pull",
                             protecting: corrections) == .accept)
    #expect(AIFixGuard.check(original: "no such wordz here", fixed: "no such words here",
                             protecting: corrections) == .accept)
    #expect(AIFixGuard.occurrences(of: ["a", "a"], in: ["a", "a", "a"]) == 2)
    #expect(AIFixGuard.occurrences(of: ["a", "b"], in: ["a"]) == 0)
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

@Test func correctLastDictationOpensTheTextAsWritten() {
    // The fixed chunks, then the fix of the rest: what the field holds, not the recognizer's text.
    #expect(AIFixTranscript.final(written: " they're here", rest: " and gone.") == "they're here and gone.")
    #expect(AIFixTranscript.final(written: "", rest: " they're here.") == "they're here.")
    // The transcript no longer extends what was written, or nothing is left: the recognized text stays.
    #expect(AIFixTranscript.final(written: " they're here", rest: nil) == nil)
    #expect(AIFixTranscript.final(written: " ", rest: "") == nil)
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
