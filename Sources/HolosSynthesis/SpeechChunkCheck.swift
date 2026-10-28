import Foundation
import HolosCore

/// The check of a rendered paragraph against its text: the words a recognizer hears compared with the words written,
/// case, accents, and punctuation ignored, and numbers written out in words on both sides first (`SpelledNumbers`, in
/// the paragraph's language), so "3.05" in the text and "three point zero five" heard compare alike, and "three point
/// five" heard does not. It fails when the edits needed exceed 15 % of the paragraph's words (at least 2, but never
/// every word: a short heading needs one word right), or when the lengths differ by more than 8 words (a cut-off or a
/// run-on take). The words of a pronunciation list's spellings ("zai mee ah" for "XIMEA") are made up, so the recognizer
/// writes them any way it can: each may be heard as any 0 to `maximumWordsPerSpelledWord` words, free (but a paragraph
/// heard as nothing fails).
public enum SpeechChunkCheck {
    public struct Verdict: Sendable, Equatable {
        public let passed: Bool
        /// Word edits (substitutions, insertions, deletions) over the written words.
        public let wordErrorRate: Double
        public let expectedWords: Int
        public let heardWords: Int
    }

    public static let maximumWordErrorRate = 0.15
    public static let minimumAllowedEdits = 2
    public static let maximumLengthDifference = 8
    public static let maximumWordsPerSpelledWord = 3

    /// `language`: the paragraph's ("en", "fr"), for writing numbers out. `spellings`: the pronunciation list's
    /// spellings in `expected` (`PronunciationList.Respelling`).
    public static func evaluate(expected: String, heard: String, language: String,
                                spellings: [String] = []) -> Verdict {
        let reference = words(expected, language: language), hypothesis = words(heard, language: language)
        let spelled = Set(spellings.flatMap { words($0, language: language) })
        let edits = editDistance(reference, hypothesis, free: { spelled.contains($0) })
        let rate = reference.isEmpty ? (hypothesis.isEmpty ? 0 : 1) : Double(edits) / Double(reference.count)
        let allowed = max(minimumAllowedEdits, Int((maximumWordErrorRate * Double(reference.count)).rounded(.down)))
        let passed = edits <= allowed && abs(reference.count - hypothesis.count) <= maximumLengthDifference
            && (reference.isEmpty || (edits < reference.count && !hypothesis.isEmpty))
        return Verdict(passed: passed, wordErrorRate: rate, expectedWords: reference.count,
                       heardWords: hypothesis.count)
    }

    /// Lowercased, accent-free words of letters and digits, numbers written out in words.
    static func words(_ text: String, language: String) -> [String] {
        SpelledNumbers.spellingOut(text, language: language)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Word edits from `lhs` to `rhs`; a `free` word of `lhs` stands for any 0 to `maximumWordsPerSpelledWord` words
    /// of `rhs` at no cost.
    static func editDistance(_ lhs: [String], _ rhs: [String], free: (String) -> Bool = { _ in false }) -> Int {
        if rhs.isEmpty { return lhs.filter { !free($0) }.count }
        if lhs.isEmpty { return rhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            let isFree = free(lhs[i - 1])
            current[0] = isFree ? previous[0] : previous[0] + 1
            for j in 1...rhs.count {
                if isFree {
                    var best = current[j - 1] + 1
                    for heard in max(0, j - maximumWordsPerSpelledWord)...j { best = min(best, previous[heard]) }
                    current[j] = best
                } else {
                    current[j] = lhs[i - 1] == rhs[j - 1] ? previous[j - 1]
                        : 1 + min(previous[j - 1], previous[j], current[j - 1])
                }
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
