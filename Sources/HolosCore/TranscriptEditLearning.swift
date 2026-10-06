import Foundation

/// What an edit of a meeting's words in Review teaches (docs/meeting-design.md §5.10, "Editing words"): learned
/// corrections ("heard" → "meant", the list dictation and meeting word fixes use), and whether the new text looks like
/// a name or term to offer for the word list. Pure; the caller says which words are dictionary words.
public enum TranscriptEditLearning {
    /// The corrections to learn from an edit of `heard` (what the recognizer wrote) into `meant`, diffed as dictation's
    /// Learn does (`CorrectionList.learn`), with the shown words `before` and `after` the span as context, so a lone
    /// dictionary word is learned only with a neighbour. Nothing for a deletion (an empty `meant`), a punctuation-only
    /// change, or a case-only change, unless the case change makes a proper noun (a word whose lowercase is not a
    /// dictionary word: "github" → "GitHub").
    /// `heardBefore`/`heardAfter`: what the recognizer wrote for the context words, when a fix changed them (nil: as
    /// shown); the heard side is the recognizer's text throughout, since corrections are matched against it.
    public static func corrections(heard: String, meant: String, before: String? = nil, after: String? = nil,
                                   heardBefore: String? = nil, heardAfter: String? = nil,
                                   isDictionaryWord: (String) -> Bool) -> [Correction] {
        let heard = words(heard), meant = words(meant)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return [] }
        // Whether the edit teaches anything is the edited words' own: a punctuation-only or case-only change stays one
        // whatever its context ("Hello" → "Hello," beside "cloud" fixed to "Claude" never teaches "Hello cloud" →
        // "Hello, Claude"), unless the case change makes a proper noun.
        guard key(heard) != key(meant)
            || makesProperNoun(from: heard, to: meant, isDictionaryWord: isDictionaryWord) else { return [] }
        let original = [heardBefore ?? before, heard, heardAfter ?? after].compactMap { $0 }.joined(separator: " ")
        let corrected = [before, meant, after].compactMap { $0 }.joined(separator: " ")
        return CorrectionList.learn(original: original, corrected: corrected,
                                    isDictionaryWord: isDictionaryWord).filter { correction in
            guard key(correction.heard) == key(correction.meant) else { return true }
            return makesProperNoun(from: correction.heard, to: correction.meant, isDictionaryWord: isDictionaryWord)
        }
    }

    /// A term to offer for the word list after an edit into `meant`: its words without the punctuation around them,
    /// when one of them is not a dictionary word, has a capital after its first letter ("iPhone"), or is a content word
    /// the edit capitalized (`heard` had it in lowercase, or not at all). At most four words and
    /// `WordList.maximumLength` characters. Nil otherwise, and for a deletion.
    public static func term(heard: String, meant: String, isDictionaryWord: (String) -> Bool,
                            isContentWord: (String) -> Bool = { SpokenWords.isContent($0) }) -> String? {
        // Each word as the word list keeps it ("C#", ".NET"; "GitHub," → "GitHub"), as ⌥Return adds it.
        let tokens = meant.split(whereSeparator: \.isWhitespace).map { WordList.termWord(String($0)) }
            .filter { !$0.isEmpty }
        guard (1...4).contains(tokens.count), tokens.contains(where: { $0.contains(where: \.isLetter) }) else {
            return nil
        }
        let term = tokens.joined(separator: " ")
        guard term.count <= WordList.maximumLength else { return nil }
        // The heard words cleaned as the term's are, so the two compare alike ("c#" heard, "C#" meant).
        let heardWords = Set(heard.split(whereSeparator: \.isWhitespace).map { WordList.termWord(String($0)) })
        let looksLikeAName = tokens.contains { word in
            guard word.contains(where: \.isLetter) else { return false }
            if !isDictionaryWord(word.lowercased()) { return true }
            if word.dropFirst().contains(where: \.isUppercase) { return true }
            guard word.first?.isUppercase == true, isContentWord(word) else { return false }
            return !heardWords.contains(word)
        }
        return looksLikeAName ? term : nil
    }

    /// The "often heard as" phrase to save with `term`: what the recognizer wrote, unless that is the term itself in
    /// another case or spacing, or longer than six words. Nil then.
    public static func heardAs(heard: String, term: String) -> String? {
        // Cleaned as the term is (`WordList.termWord`): "c#" stays "c#", the same as "C#" in another case, never the
        // broader "c".
        let phrase = heard.split(whereSeparator: \.isWhitespace).map { WordList.termWord(String($0)) }
            .filter { !$0.isEmpty }
        guard !phrase.isEmpty, phrase.count <= 6 else { return nil }
        let joined = phrase.joined(separator: " ")
        guard WordList.isHeardAs(joined, of: term) else { return nil }
        return joined
    }

    /// Whitespace collapsed, trimmed.
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Each word's letters and digits, lowercased, words kept apart: what a punctuation-only or case-only change leaves
    /// equal. Splitting or joining words ("everyday" → "every day") changes it.
    static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A case change that capitalizes a word that is not a dictionary word: every word whose letters changed case
    /// gained a capital, and none of them is a dictionary word in lowercase.
    private static func makesProperNoun(from heard: String, to meant: String,
                                        isDictionaryWord: (String) -> Bool) -> Bool {
        let old = heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = meant.split(whereSeparator: \.isWhitespace).map(String.init)
        guard old.count == new.count else { return false }
        let changed = zip(old, new).filter { $0.0 != $0.1 }
        guard !changed.isEmpty else { return false }
        return changed.allSatisfy { before, after in
            key(before) == key(after) && after.filter(\.isUppercase).count > before.filter(\.isUppercase).count
                && !isDictionaryWord(String(after.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }))
        }
    }
}
