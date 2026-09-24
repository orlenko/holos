import Foundation

public struct Correction: Codable, Sendable, Equatable, Hashable {
    public var heard: String
    public var meant: String

    public init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

/// Phrase replacements learned from the user's fixes. Matching is whole-word, case-insensitive,
/// and tolerant of whitespace differences inside a phrase.
public struct CorrectionList: Codable, Sendable, Equatable {
    public private(set) var entries: [Correction] = []

    public init(entries: [Correction] = []) {
        for entry in entries { add(entry) }
    }

    public static var defaultURL: URL {
        HolosPaths.applicationSupport.appendingPathComponent("corrections.json")
    }

    /// Phrases the recognizer should expect.
    public var vocabulary: [String] {
        var seen = Set<String>()
        return entries.map(\.meant).filter { seen.insert(Self.normalized($0)).inserted }
    }

    /// Adds or replaces the entry for the same heard phrase. Blank or identical pairs are ignored.
    public mutating func add(_ correction: Correction) {
        let heard = correction.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = correction.meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return }
        let key = Self.normalized(heard)
        entries.removeAll { Self.normalized($0.heard) == key }
        entries.append(Correction(heard: heard, meant: meant))
    }

    public mutating func remove(_ correction: Correction) {
        entries.removeAll { $0 == correction }
    }

    public func apply(to text: String) -> String {
        guard !entries.isEmpty, let pattern = matcher() else { return text }
        let replacements = Dictionary(entries.map { (Self.normalized($0.heard), $0) },
                                      uniquingKeysWith: { _, last in last })
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let found = source.substring(with: match.range)
            guard let entry = replacements[Self.normalized(found)] else { continue }
            var meant = entry.meant
            // A capital the saved phrase lacks came from sentence position, so carry it over; a saved
            // capital ("Mac OS" → "macOS") means the lowercase replacement is deliberate.
            if let first = found.first, first.isUppercase, entry.heard.first?.isLowercase == true,
               let head = meant.first, head.isLowercase {
                meant = head.uppercased() + meant.dropFirst()
            }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += meant
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }

    /// For text still growing while the user speaks: withholds trailing words that could become the start
    /// of a multi-word phrase once more words arrive, then applies corrections to the rest. Withholding is
    /// decided on the uncorrected text, so a shorter rule cannot consume the start of a longer one.
    public func applyWithholdingPartialMatch(to text: String) -> String {
        let words = Self.words(in: text)
        var withheld = 0
        for entry in entries {
            let heard = Self.normalized(entry.heard).split(separator: " ").map(String.init)
            guard heard.count > 1 else { continue }
            for length in stride(from: min(heard.count - 1, words.count), to: withheld, by: -1) {
                let tail = words.suffix(length).map { text[$0].lowercased() }
                if tail == Array(heard.prefix(length)) { withheld = length; break }
            }
        }
        guard withheld > 0 else { return apply(to: text) }
        let cut = words[words.count - withheld].lowerBound
        return apply(to: String(text[..<cut]).trimmingCharacters(in: .whitespaces))
    }

    /// Word-level substitutions between a transcript and the user's fixed version. Pure insertions,
    /// deletions, and rewrites longer than a few words are ignored as rewording rather than mishearing.
    /// A single misheard word that is itself a dictionary word keeps a neighbouring word as context,
    /// so "bull" → "pull" is learned as "bull request" → "pull request" rather than rewriting every "bull".
    public static func learn(original: String, corrected: String,
                             isDictionaryWord: (String) -> Bool = { _ in false }) -> [Correction] {
        learnReportingDeclined(original: original, corrected: corrected, isDictionaryWord: isDictionaryWord).learned
    }

    /// Like `learn`, and also returns single dictionary-word swaps that were not learned because no
    /// neighbouring word could anchor them, so the caller can explain why and offer to add them by hand.
    public static func learnReportingDeclined(original: String, corrected: String,
                                              isDictionaryWord: (String) -> Bool = { _ in false })
        -> (learned: [Correction], declined: [Correction]) {
        let a = tokens(in: original)
        let b = tokens(in: corrected)
        guard !a.isEmpty, !b.isEmpty, a.count <= 2_000, b.count <= 2_000 else { return ([], []) }
        let aText = a.map { String(original[$0]) }
        let bText = b.map { String(corrected[$0]) }

        // Longest common subsequence over exact tokens.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = aText[i] == bText[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var hunks: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, aText[i] == bText[j] { i += 1; j += 1; continue }
            let (startA, startB) = (i, j)
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, aText[i] == bText[j] { break }
                if j == b.count || (i < a.count && table[i + 1][j] >= table[i][j + 1]) { i += 1 } else { j += 1 }
            }
            hunks.append((startA..<i, startB..<j))
        }

        let maximumTokens = 6
        var learned: [Correction] = []
        var declined: [Correction] = []
        for (rangeA, rangeB) in hunks {
            guard !rangeA.isEmpty, !rangeB.isEmpty,
                  rangeA.count <= maximumTokens, rangeB.count <= maximumTokens,
                  rangeA.contains(where: { isWord(aText[$0]) }),
                  rangeB.contains(where: { isWord(bText[$0]) }) else { continue }
            var spanA = rangeA, spanB = rangeB
            if rangeA.count == 1, isDictionaryWord(aText[rangeA.lowerBound]) {
                // Neighbours are shared by both texts because the hunk is bounded by equal tokens.
                if spanA.upperBound < a.count, isWord(aText[spanA.upperBound]) {
                    spanA = spanA.lowerBound..<spanA.upperBound + 1
                    spanB = spanB.lowerBound..<spanB.upperBound + 1
                } else if spanA.lowerBound > 0, isWord(aText[spanA.lowerBound - 1]) {
                    spanA = spanA.lowerBound - 1..<spanA.upperBound
                    spanB = spanB.lowerBound - 1..<spanB.upperBound
                } else {
                    // No neighbouring word: a bare dictionary-word rule would rewrite unrelated text.
                    let meant = corrected[b[rangeB.lowerBound].lowerBound..<b[rangeB.upperBound - 1].upperBound]
                    declined.append(Correction(heard: aText[rangeA.lowerBound], meant: String(meant)))
                    continue
                }
            }
            let heard = String(original[a[spanA.lowerBound].lowerBound..<a[spanA.upperBound - 1].upperBound])
            let meant = String(corrected[b[spanB.lowerBound].lowerBound..<b[spanB.upperBound - 1].upperBound])
            learned.append(Correction(heard: heard, meant: meant))
        }
        return (learned, declined)
    }

    public static func load(from url: URL) throws -> CorrectionList {
        guard FileManager.default.fileExists(atPath: url.path) else { return CorrectionList() }
        return try JSONDecoder().decode(CorrectionList.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private func matcher() -> NSRegularExpression? {
        let alternatives = entries.map(\.heard)
            .sorted { $0.count > $1.count }
            .map { $0.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+") }
        let pattern = "(?<![\\p{L}\\p{N}'’])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}'’])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /\S+/)
    }

    /// Words (letters, digits, apostrophes) and single punctuation marks.
    private static func tokens(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /[\p{L}\p{N}'’]+|[^\s\p{L}\p{N}'’]/)
    }

    private static func isWord(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }
}
