import Foundation
@testable import HolosCore
import Testing

// What an edit of a meeting's words in Review teaches (docs/meeting-design.md §5.10, "Editing words").

/// A small dictionary: these words, in lowercase, are real words.
private let dictionary: Set<String> = ["ask", "the", "now", "pull", "bull", "request", "apple", "so", "think", "we",
                                       "use", "daily", "and", "mark", "mike", "cloud", "dont", "here", "new", "work",
                                       "knew", "york"]
private func isWord(_ word: String) -> Bool { dictionary.contains(word.lowercased()) }

@Test func anEditTeachesWhatTheRecognizerMisheard() {
    #expect(TranscriptEditLearning.corrections(heard: "cloud", meant: "Claude", before: "ask", after: "now",
                                               isDictionaryWord: isWord)
        == [Correction(heard: "cloud now", meant: "Claude now")],
        "A lone dictionary word is learned with its neighbour, the next one first.")
    #expect(TranscriptEditLearning.corrections(heard: "cooper netties", meant: "Kubernetes", isDictionaryWord: isWord)
        == [Correction(heard: "cooper netties", meant: "Kubernetes")])
    #expect(TranscriptEditLearning.corrections(heard: "bull", meant: "pull", before: "a", after: "request",
                                               isDictionaryWord: isWord)
        == [Correction(heard: "bull request", meant: "pull request")])
    // Without a neighbour, a dictionary word on its own is not learned (it would rewrite unrelated speech).
    #expect(TranscriptEditLearning.corrections(heard: "bull", meant: "pull", isDictionaryWord: isWord).isEmpty)
}

@Test func trivialEditsTeachNothing() {
    // A deletion.
    #expect(TranscriptEditLearning.corrections(heard: "um think", meant: "think", isDictionaryWord: isWord).isEmpty)
    #expect(TranscriptEditLearning.corrections(heard: "um", meant: "", isDictionaryWord: isWord).isEmpty)
    // Punctuation only.
    #expect(TranscriptEditLearning.corrections(heard: "now,", meant: "now.", before: "ask", isDictionaryWord: isWord)
        .isEmpty)
    #expect(TranscriptEditLearning.corrections(heard: "dont", meant: "don't", isDictionaryWord: isWord).isEmpty)
    // Case only, of a dictionary word (a sentence start, or a common word made a name).
    #expect(TranscriptEditLearning.corrections(heard: "so", meant: "So", after: "we", isDictionaryWord: isWord)
        .isEmpty)
    #expect(TranscriptEditLearning.corrections(heard: "apple", meant: "Apple", before: "we", after: "use",
                                               isDictionaryWord: isWord).isEmpty)
    // The same text.
    #expect(TranscriptEditLearning.corrections(heard: "ask  now", meant: "ask now", isDictionaryWord: isWord).isEmpty)
}

@Test func whetherAnEditTeachesIsDecidedOnTheEditedWordsAloneNotTheirContext() {
    // "Hello cloud welcome back", whose "cloud" a correction made "Claude": only "Hello" → "Hello," was edited. The
    // context's own change ("cloud" → "Claude") never makes a punctuation-only edit teach "Hello cloud" → "Hello, Claude".
    #expect(TranscriptEditLearning.corrections(heard: "Hello", meant: "Hello,", after: "Claude", heardAfter: "cloud",
                                               isDictionaryWord: { _ in true }).isEmpty)
    #expect(TranscriptEditLearning.corrections(heard: "so", meant: "So", after: "Claude", heardAfter: "cloud",
                                               isDictionaryWord: isWord).isEmpty, "Nor a case-only one.")
    // A real edit beside the fixed word is learned against what the recognizer wrote there.
    #expect(TranscriptEditLearning.corrections(heard: "as", meant: "ask", after: "Claude", heardAfter: "cloud",
                                               isDictionaryWord: { _ in true })
        == [Correction(heard: "as cloud", meant: "ask Claude")])
    // A case change making a proper noun still teaches, beside a fixed word too.
    #expect(!TranscriptEditLearning.corrections(heard: "github", meant: "GitHub", after: "Claude", heardAfter: "cloud",
                                                isDictionaryWord: isWord).isEmpty)
}

@Test func splittingOrJoiningWordsIsLearned() {
    // Only the spaces differ, which is no punctuation-only or case-only change.
    #expect(TranscriptEditLearning.corrections(heard: "everyday", meant: "every day", isDictionaryWord: { _ in false })
        == [Correction(heard: "everyday", meant: "every day")])
    #expect(TranscriptEditLearning.corrections(heard: "grand mother", meant: "grandmother",
                                               isDictionaryWord: { _ in false })
        == [Correction(heard: "grand mother", meant: "grandmother")])
    #expect(TranscriptEditLearning.key("Every, day.") == "every day" && TranscriptEditLearning.key("everyday") == "everyday")
}

@Test func aCaseChangeToAProperNounIsLearned() {
    #expect(TranscriptEditLearning.corrections(heard: "github", meant: "GitHub", before: "we", after: "use",
                                               isDictionaryWord: isWord)
        == [Correction(heard: "github", meant: "GitHub")])
}

@Test func aTypedTermLosesOnlyTheSentencesPunctuation() {
    #expect(WordList.typedTerm("C#") == "C#")
    #expect(WordList.typedTerm("C++,") == "C++")
    #expect(WordList.typedTerm(".NET") == ".NET")
    #expect(WordList.typedTerm("Node.js") == "Node.js")
    #expect(WordList.typedTerm("GitHub,") == "GitHub")
    #expect(WordList.typedTerm("Claude.") == "Claude")
    #expect(WordList.typedTerm("(Jean-Luc!)") == "Jean-Luc")
    #expect(WordList.typedTerm("e.g.") == "e.g.", "A dot is the word's when it has others.")
    #expect(WordList.typedTerm(" New York, ") == "New York")
    #expect(WordList.typedTerm("“…”") == nil)
    // A sentence's mark after a closing bracket or quote, and the wrapper, in either order; the word's own kept.
    #expect(WordList.typedTerm("(Claude).") == "Claude")
    #expect(WordList.typedTerm("“Claude”.") == "Claude")
    #expect(WordList.typedTerm("“Claude.”") == "Claude")
    #expect(WordList.typedTerm("(Claude.)!") == "Claude")
    #expect(WordList.typedTerm("(Node.js).") == "Node.js")
    #expect(WordList.typedTerm("“C#”,") == "C#")
    #expect(WordList.typedTerm("(.NET).") == ".NET")
    #expect(WordList.typedTerm("Node.js.") == "Node.js.", "A dot after a word with its own is left, as before.")
}

@Test func theHeardSideIsCleanedAsTheTermIs() {
    // A case-only change: no alias, never the broader "c" for "C#".
    #expect(TranscriptEditLearning.heardAs(heard: "c#", term: "C#") == nil)
    #expect(TranscriptEditLearning.heardAs(heard: "c++", term: "C++") == nil)
    #expect(TranscriptEditLearning.heardAs(heard: ".net", term: ".NET") == nil)
    #expect(TranscriptEditLearning.heardAs(heard: "github,", term: "GitHub") == nil)
    // A real alias keeps its own punctuation and loses the sentence's.
    #expect(TranscriptEditLearning.heardAs(heard: "see sharp,", term: "C#") == "see sharp")
    #expect(TranscriptEditLearning.heardAs(heard: "c,", term: "C#") == "c")
}

@Test func aProperNounCaseChangeTeachesOnlyTheCasing() {
    // The punctuation changed along with the case ("," became ".") is never part of the lesson.
    let learned = TranscriptEditLearning.corrections(heard: "github,", meant: "GitHub.", isDictionaryWord: isWord)
    #expect(learned == [Correction(heard: "github", meant: "GitHub")])
    #expect(!learned.contains { $0.meant.contains(".") || $0.heard.contains(",") })
    // With context, the same: only the casing of the edited word.
    #expect(TranscriptEditLearning.corrections(heard: "github,", meant: "GitHub.", before: "we", after: "use",
                                               isDictionaryWord: isWord)
        == [Correction(heard: "github", meant: "GitHub")])
    // A punctuation-only change still teaches nothing.
    #expect(TranscriptEditLearning.corrections(heard: "GitHub,", meant: "GitHub.", isDictionaryWord: isWord).isEmpty)
}

@Test func aNameOrTermIsOfferedForTheWordList() {
    // Not a dictionary word.
    #expect(TranscriptEditLearning.term(heard: "cloud", meant: "Claude", isDictionaryWord: isWord) == "Claude")
    // A capital inside a word, with the punctuation around it left out.
    #expect(TranscriptEditLearning.term(heard: "i phone", meant: "iPhone,", isDictionaryWord: { _ in true })
        == "iPhone")
    // A content word the edit capitalized.
    #expect(TranscriptEditLearning.term(heard: "mike", meant: "Mark", isDictionaryWord: isWord) == "Mark")
    // A function word at a sentence start, a plain word, a deletion, and a long rewrite are not.
    #expect(TranscriptEditLearning.term(heard: "so", meant: "So", isDictionaryWord: isWord,
                                        isContentWord: { $0.lowercased() != "so" }) == nil)
    #expect(TranscriptEditLearning.term(heard: "bull", meant: "pull", isDictionaryWord: isWord) == nil)
    #expect(TranscriptEditLearning.term(heard: "um", meant: "", isDictionaryWord: isWord) == nil)
    #expect(TranscriptEditLearning.term(heard: "a", meant: "One Two Three Four Five", isDictionaryWord: { _ in false })
        == nil)
    // A word kept capitalized as it was heard is not news.
    #expect(TranscriptEditLearning.term(heard: "Mark said", meant: "Mark says", isDictionaryWord: { _ in true },
                                        isContentWord: { _ in true }) == nil)
}

/// Each meant word is compared with the heard word it stands for, never with the heard words as a set.
@Test func aWordCountsAsCapitalizedOnlyAgainstItsOwnHeardWord() {
    let word = { (_: String) in true }
    let content = { (_: String) in true }
    // Capitals made lowercase are not a name.
    #expect(TranscriptEditLearning.term(heard: "APPLE", meant: "Apple", isDictionaryWord: word,
                                        isContentWord: content) == nil)
    // The second "apple" was capitalized, though the first was already: offered.
    #expect(TranscriptEditLearning.term(heard: "Apple apple", meant: "Apple Apple", isDictionaryWord: word,
                                        isContentWord: content) == "Apple Apple")
    // Lowercase to a capital, and a capitalized word put in: offered; as heard: not.
    #expect(TranscriptEditLearning.term(heard: "apple", meant: "Apple", isDictionaryWord: word,
                                        isContentWord: content) == "Apple")
    #expect(TranscriptEditLearning.term(heard: "the pie", meant: "the Apple pie", isDictionaryWord: word,
                                        isContentWord: { $0 != "the" }) == "the Apple pie")
    #expect(TranscriptEditLearning.term(heard: "Apple pie", meant: "Apple pie", isDictionaryWord: word,
                                        isContentWord: content) == nil)
    #expect(TranscriptEditLearning.aligned(["Apple", "Apple"], with: ["Apple", "apple"]) == ["Apple", "apple"])
}

@Test func oftenHeardAsIsWhatTheRecognizerWrote() {
    #expect(TranscriptEditLearning.heardAs(heard: "cloud,", term: "Claude") == "cloud")
    #expect(TranscriptEditLearning.heardAs(heard: "github", term: "GitHub") == nil, "The term itself in another case.")
    #expect(TranscriptEditLearning.heardAs(heard: "one two three four five six seven", term: "X") == nil)
    #expect(TranscriptEditLearning.heardAs(heard: " ", term: "X") == nil)
}
