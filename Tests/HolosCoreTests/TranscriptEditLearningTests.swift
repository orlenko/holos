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

@Test func oftenHeardAsIsWhatTheRecognizerWrote() {
    #expect(TranscriptEditLearning.heardAs(heard: "cloud,", term: "Claude") == "cloud")
    #expect(TranscriptEditLearning.heardAs(heard: "github", term: "GitHub") == nil, "The term itself in another case.")
    #expect(TranscriptEditLearning.heardAs(heard: "one two three four five six seven", term: "X") == nil)
    #expect(TranscriptEditLearning.heardAs(heard: " ", term: "X") == nil)
}
