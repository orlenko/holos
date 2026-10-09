import Foundation
import HolosCore

/// The check of a rendered paragraph against its text: the words a recognizer hears compared with the words written,
/// case, accents, and punctuation ignored, and numbers written out in words on both sides first (`SpelledNumbers`, in
/// the paragraph's language), so "3.05" in the text and "three point zero five" heard compare alike, and "three point
/// five" heard does not. It fails when the edits needed exceed 15 % of the paragraph's words (at least 2, but never
/// every word: a short heading needs one word right), or when the lengths differ by more than 8 words (a cut-off or a
/// run-on take).
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

    /// `language`: the paragraph's ("en", "fr"), for writing numbers out.
    public static func evaluate(expected: String, heard: String, language: String) -> Verdict {
        let reference = words(expected, language: language), hypothesis = words(heard, language: language)
        let edits = editDistance(reference, hypothesis)
        let rate = reference.isEmpty ? (hypothesis.isEmpty ? 0 : 1) : Double(edits) / Double(reference.count)
        let allowed = max(minimumAllowedEdits, Int((maximumWordErrorRate * Double(reference.count)).rounded(.down)))
        let passed = edits <= allowed && abs(reference.count - hypothesis.count) <= maximumLengthDifference
            && (reference.isEmpty || edits < reference.count)
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

    static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                current[j] = lhs[i - 1] == rhs[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
