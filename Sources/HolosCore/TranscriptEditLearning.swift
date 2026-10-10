import Foundation

/// What an edit of a meeting's words in Review teaches (docs/meeting/review-window.md §5.10, "Editing words"): learned
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
        let heard = words(heard)
        var meant = words(meant)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return [] }
        // Whether the edit teaches anything is the edited words' own: a punctuation-only or case-only change stays one
        // whatever its context ("Hello" → "Hello," beside "cloud" fixed to "Claude" never teaches "Hello cloud" →
        // "Hello, Claude"), unless the case change makes a proper noun. That one teaches only the casing, never
        // punctuation changed with it ("github," → "GitHub." teaches "github" → "GitHub").
        if key(heard) == key(meant) {
            guard makesProperNoun(from: heard, to: meant, isDictionaryWord: isDictionaryWord) else { return [] }
            meant = casing(of: meant, onto: heard)
        }
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
        // The heard words cleaned as the term's are, so the two compare alike ("c#" heard, "C#" meant), each meant word
        // matched with the heard word it stands for (`aligned`): one word against its own, never against the set.
        let heardWords = heard.split(whereSeparator: \.isWhitespace).map { WordList.termWord(String($0)) }
            .filter { !$0.isEmpty }
        let counterpart = aligned(tokens, with: heardWords)
        let looksLikeAName = tokens.indices.contains { index in
            let word = tokens[index]
            guard word.contains(where: \.isLetter) else { return false }
            if !isDictionaryWord(word.lowercased()) { return true }
            if word.dropFirst().contains(where: \.isUppercase) { return true }
            guard word.first?.isUppercase == true, isContentWord(word) else { return false }
            // Capitalized by the edit: a word the recognizer did not write (inserted), or its own word written with a
            // lowercase first letter ("apple" → "Apple"; never "APPLE" → "Apple").
            guard let heardWord = counterpart[index] else { return true }
            return heardWord.first?.isLowercase == true
        }
        return looksLikeAName ? term : nil
    }

    /// For each of `meant`'s words, the word of `heard` it stands for: the two aligned in order on the words equal
    /// but for case (a longest common subsequence), nil for a word `heard` has no counterpart for (inserted or
    /// replaced).
    static func aligned(_ meant: [String], with heard: [String]) -> [String?] {
        let a = meant.map { $0.lowercased() }
        let b = heard.map { $0.lowercased() }
        // Lengths of the longest common subsequences of the suffixes (at most four meant words, so small).
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var result = [String?](repeating: nil, count: meant.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result[i] = heard[j]
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
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

    /// Whether an edit of `heard` into `meant` changes only punctuation or letter case (`key`): it teaches nothing
    /// beside other edits, only on its own (a case change making a proper noun teaches its casing, `corrections`).
    public static func changesOnlyPunctuationOrCase(heard: String, meant: String) -> Bool {
        key(heard) == key(meant)
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

    /// `heard` with the case of `meant`'s letters and digits, its own punctuation kept: what a case change teaches.
    /// The two have the same letters and digits word by word (`key`); `meant` as it is otherwise.
    private static func casing(of meant: String, onto heard: String) -> String {
        let old = heard.split(whereSeparator: \.isWhitespace)
        let new = meant.split(whereSeparator: \.isWhitespace)
        guard old.count == new.count else { return meant }
        return zip(old, new).map { before, after -> String in
            var cased = after.filter { $0.isLetter || $0.isNumber }.makeIterator()
            let word = String(before.map { character -> Character in
                guard character.isLetter || character.isNumber else { return character }
                return cased.next() ?? character
            })
            // Letters that do not line up one for one ("ß" against "SS"): as meant.
            return word.lowercased() == before.lowercased() ? word : String(after)
        }.joined(separator: " ")
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
