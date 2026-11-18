import Foundation

/// Speaker labels and prompt roll-call lists Whisper writes into a passage that nobody said ("Jane Doe: Yes.",
/// "Jane Doe- Yes.", "Jane Doe-Smith, Omar, Lena, …"), as the transcripts it learned from and the vocabulary prompt
/// put them (docs/meeting/deep-transcription.md §4.16). Pure.
public enum DeepTranscribedLabel {
    /// The most words one name or title in a label has, its colon or dash word included ("Dr. Jane Q. Doe:").
    public static let labelMaxWords = 5
    /// The most words a comma-separated speaker header ending in ":" has ("Jane Doe-Smith, Omar, Lena, M.D.:").
    public static let labelMaxListWords = 15
    /// Lowercase words a name may hold.
    public static let nameParticles: Set<String> = [
        "al", "bin", "da", "das", "de", "del", "della", "den", "der", "di", "do", "dos", "du", "el", "la", "le",
        "van", "von", "y",
    ]
    /// Titles and degrees (as letters, "Ph.D." being "ph" and "d"): not looked for in the recorded transcript.
    public static let labelTitles: Set<String> = ["d", "dr", "jr", "md", "mr", "mrs", "ms", "ph", "phd", "prof", "sr"]
    /// Short common English words that never start a dash speaker label or a colon-less prompt list.
    private static let stopFirstWords: Set<String> = [
        "and", "as", "at", "be", "but", "by", "do", "for", "go", "he", "if", "in", "is", "it", "my", "no", "of",
        "ok", "okay", "on", "or", "so", "to", "up", "we", "well", "yeah", "yes",
    ]
    private static let dashes: Set<String> = ["-", "--", "–", "—"]

    /// One invented label or prompt list found from a start index in a passage's words.
    public struct Match: Sendable, Equatable {
        /// The last word index of the label (`start...end`).
        public var end: Int
        /// A colon-less comma-separated roll-call list at the start of a passage: kept when any of its words was said
        /// there, whereas a speaker label (`:` or `-`) is kept only when every non-title word of it was said there.
        public var isList = false
        /// The next word (`end + 1`) begins with an unspaced "-" that belongs to the label ("Jane" "Doe" "-Making"):
        /// removing `start...end` also replaces that leading "-" with a space.
        public var unhyphenateNext = false

        public init(end: Int, isList: Bool = false, unhyphenateNext: Bool = false) {
            self.end = end; self.isList = isList; self.unhyphenateNext = unhyphenateNext
        }
    }

    /// The label starting at `start` in `words` (when `start` is the start of the passage or follows a word ending a
    /// sentence); nil when none starts there.
    public static func match(_ words: [DeepTranscribedWord], from start: Int) -> Match? {
        guard start >= 0, start < words.count,
              start == 0 || endsSentence(words[start - 1].text) else { return nil }
        if let colon = colonMatch(words, from: start) { return colon }
        if start == 0, let list = listMatch(words, from: start) { return list }
        return hyphenMatch(words, from: start)
    }

    /// How many invented labels and label words `words` holds by shape alone (without a recorded transcript).
    public static func count(in words: [DeepTranscribedWord]) -> (labels: Int, words: Int) {
        var copy = words
        var labels = 0, removed = 0, index = 0
        while index < copy.count {
            if let found = match(copy, from: index) {
                if found.unhyphenateNext, found.end + 1 < copy.count {
                    copy[found.end + 1].text = unhyphenated(copy[found.end + 1].text)
                }
                removed += found.end - index + 1
                copy.removeSubrange(index...found.end)
                labels += 1
                continue
            }
            index += 1
        }
        return (labels, removed)
    }

    /// Lowercased letters and digits, words separated by one space.
    public static func normalized(_ text: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            cleaned.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// The normalized non-title words of `label`.
    public static func labelNames(_ label: ArraySlice<DeepTranscribedWord>) -> [String] {
        label.flatMap { normalized($0.text).split(separator: " ").map(String.init) }
            .filter { !labelTitles.contains($0) }
    }

    /// `text` with its leading "-" replaced by a single leading space.
    public static func unhyphenated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") else { return text }
        return " " + trimmed.dropFirst()
    }

    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    private static func colonMatch(_ words: [DeepTranscribedWord], from start: Int) -> Match? {
        var itemWords = 0
        for index in start..<min(words.count, start + labelMaxListWords) {
            let text = words[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == ":" { return index > start ? Match(end: index) : nil }
            guard isLabelWord(text) else { return nil }
            itemWords += 1
            guard itemWords <= labelMaxWords else { return nil }
            if text.hasSuffix(":") { return Match(end: index) }
            if text.hasSuffix(",") {
                itemWords = 0
            } else if text.hasSuffix(".") {
                let nextIsColon = index + 1 < words.count
                    && words[index + 1].text.trimmingCharacters(in: .whitespacesAndNewlines) == ":"
                if !nextIsColon, !continuesPastPeriod(text) { return nil }
            }
        }
        return nil
    }

    private static func listMatch(_ words: [DeepTranscribedWord], from start: Int) -> Match? {
        guard !stopFirstWords.contains(normalized(words[start].text)) else { return nil }
        var commas = 0, upperItems = 0, itemWords = 0, spacedWords = 0
        var itemHasUpper = false
        var lastEnd: Int?
        for index in start..<words.count {
            let raw = words[index].text
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLabelWord(text), !text.hasSuffix(":") else { break }
            if index == start || raw.first?.isWhitespace == true || (text.first != "." && text.first != "-") {
                itemWords += 1
                spacedWords += 1
            }
            if text.contains(where: \.isUppercase) { itemHasUpper = true }
            guard itemWords <= labelMaxWords else { break }
            if text.hasSuffix(",") {
                commas += 1
                if itemHasUpper { upperItems += 1 }
                itemHasUpper = false
                itemWords = 0
                if commas >= 2, upperItems >= 2, spacedWords >= 3 { lastEnd = index }
            } else if text.hasSuffix(".") || index == words.count - 1, commas >= 1 {
                let totalUpper = upperItems + (itemHasUpper ? 1 : 0)
                if totalUpper >= 2, spacedWords >= 3 { lastEnd = index }
                if text.hasSuffix("."), !continuesPastPeriod(text) { break }
            }
        }
        return lastEnd.map { Match(end: $0, isList: true) }
    }

    private static func hyphenMatch(_ words: [DeepTranscribedWord], from start: Int) -> Match? {
        guard !stopFirstWords.contains(normalized(words[start].text)) else { return nil }
        for index in start..<min(words.count, start + labelMaxWords + 1) {
            let text = words[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if index - start >= 2, text.hasPrefix("-"),
               let first = text.dropFirst().first, first.isUppercase || first.isNumber {
                if text.hasSuffix(",") { return Match(end: index) }
                return Match(end: index - 1, unhyphenateNext: true)
            }
            guard index - start < labelMaxWords, isStrictNameWord(text) else { return nil }
            let endsWithDash = text.hasSuffix("-") || text.hasSuffix("–") || text.hasSuffix("—")
            if index > start {
                if endsWithDash { return Match(end: index) }
                if index + 1 < words.count,
                   dashes.contains(words[index + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return Match(end: index + 1)
                }
            }
            if endsWithDash { return nil }
        }
        return nil
    }

    private static func isLabelWord(_ text: String) -> Bool {
        let core = text.drop { $0.isPunctuation || $0.isSymbol }
        guard let first = core.first else { return false }
        if first.isUppercase || first.isNumber { return true }
        return nameParticles.contains(core.trimmingCharacters(in: .punctuationCharacters))
    }

    private static func isStrictNameWord(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: CharacterSet(charactersIn: "-–—"))
        guard !core.isEmpty else { return false }
        if nameParticles.contains(core) { return true }
        return core.count >= 2 && core.first?.isUppercase == true && core.allSatisfy(\.isLetter)
    }

    private static func continuesPastPeriod(_ text: String) -> Bool {
        let parts = normalized(text).split(separator: " ").map(String.init)
        return !parts.isEmpty && parts.allSatisfy { labelTitles.contains($0) || $0.count == 1 }
    }
}
