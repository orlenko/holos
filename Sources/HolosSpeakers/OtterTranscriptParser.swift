import Foundation

/// One speaker turn of a reference transcript. The text is counted, never kept, so evaluation code can hold
/// references without holding what was said (docs/meeting-design.md §1.9).
public struct ReferenceTurn: Sendable, Equatable {
    public var speaker: String
    /// Seconds from the start of the recording.
    public var start: Double
    /// The next turn's start; nil for the last turn.
    public var end: Double?
    /// Words in the turn's text lines.
    public var wordCount: Int

    public init(speaker: String, start: Double, end: Double? = nil, wordCount: Int = 0) {
        self.speaker = speaker; self.start = start; self.end = end; self.wordCount = wordCount
    }
}

/// The speaker name is private reference data: printing, `dump`, and test-failure output show times and the word
/// count only (docs/meeting-design.md §1.9).
extension ReferenceTurn: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ReferenceTurn(start: \(start), end: \(end.map { "\($0)" } ?? "nil"), wordCount: \(wordCount))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["start": start, "end": end as Any, "wordCount": wordCount], displayStyle: .struct)
    }
}

/// Reads Otter's plain-text export (and Holos's `transcript.txt`, which uses the same layout).
public enum OtterTranscriptParser {
    /// Header lines "Name  mm:ss" or "Name  h:mm:ss" start turns; the footer "Transcribed by https://otter.ai" is
    /// ignored.
    ///
    /// A header is exactly a line the evaluator's regex (`evaluatorHeaderPattern`, the same text as in
    /// scripts/evaluate-references.swift) accepts: the name is the text before the last run of two or more whitespace
    /// characters, trimmed, and the time after it is one- or two-digit minutes and seconds, or hours (one or more
    /// digits, so a Holos export past 99 hours still reads), minutes, and seconds. The footer is the evaluator's
    /// case-insensitive `Transcribed by http(s)://otter.ai` line. Any other line adds its words (counted as the
    /// evaluator counts them: runs of letters and digits) to the current turn; lines before the first header belong
    /// to no turn. Turns keep file order; `end` is the next turn's start as written. A leading byte-order mark is
    /// dropped, so it never becomes part of the first speaker's name.
    public static func parse(_ text: String) -> [ReferenceTurn] {
        guard let header = headerRegex, let footer = footerRegex, let words = wordRegex else { return [] }
        let text = text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
        var turns: [ReferenceTurn] = []
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = header.firstMatch(in: line, range: range), let turn = turn(from: match, in: line) {
                turns.append(turn)
                continue
            }
            if footer.firstMatch(in: line, range: range) != nil { continue }
            guard !turns.isEmpty else { continue }
            turns[turns.count - 1].wordCount += wordCount(line, words: words)
        }
        for index in turns.indices.dropLast() {
            turns[index].end = turns[index + 1].start
        }
        return turns
    }

    /// The header regex of scripts/evaluate-references.swift, character for character: `h:mm:ss` with one or more
    /// hour digits, or `mm:ss` with one or two minute digits (Otter's layouts, and Holos's past 99 hours).
    static let evaluatorHeaderPattern = #"^\s*\S.*\s{2,}(?:\d+:\d{2}:\d{2}|\d{1,2}:\d{2})\s*$"#

    /// `evaluatorHeaderPattern` with capture groups: the name, then hours, minutes, and seconds (groups 2–4) or
    /// minutes and seconds (groups 5–6). Lazy and greedy name matches accept the same lines; the time must end the
    /// line either way.
    static let headerPattern = #"^\s*(\S.*?)\s{2,}(?:(\d+):(\d{2}):(\d{2})|(\d{1,2}):(\d{2}))\s*$"#
    static let footerPattern = #"(?i)^\s*transcribed by\s+https?://otter\.ai/?\s*$"#
    static let wordPattern = #"[\p{L}\p{N}]+"#

    // Compiled once; NSRegularExpression is immutable and safe to share across threads.
    nonisolated(unsafe) private static let headerRegex = try? NSRegularExpression(pattern: headerPattern)
    nonisolated(unsafe) private static let footerRegex = try? NSRegularExpression(pattern: footerPattern)
    nonisolated(unsafe) private static let wordRegex = try? NSRegularExpression(pattern: wordPattern)

    private static func turn(from match: NSTextCheckingResult, in line: String) -> ReferenceTurn? {
        func group(_ index: Int) -> Substring? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return line[range]
        }
        guard let name = group(1) else { return nil }
        let seconds: Double
        if let hours = group(2).flatMap(number), let minutes = group(3).flatMap(number),
           let secondsPart = group(4).flatMap(number) {
            seconds = hours * 3_600 + minutes * 60 + secondsPart
        } else if let minutes = group(5).flatMap(number), let secondsPart = group(6).flatMap(number) {
            seconds = minutes * 60 + secondsPart
        } else {
            return nil
        }
        let speaker = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speaker.isEmpty else { return nil }
        return ReferenceTurn(speaker: speaker, start: seconds)
    }

    /// The value of a run of decimal digits (`\d` also matches non-ASCII digits). Summed as a `Double`, so any number
    /// of hour digits reads without overflow.
    private static func number(_ digits: Substring) -> Double? {
        var value = 0.0
        for character in digits {
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            value = value * 10 + Double(digit)
        }
        return value
    }

    /// The evaluator's word count (`tokens` in scripts/evaluate-references.swift): runs of letters and digits after
    /// NFKC and lowercasing, so "don't" and "12:30" are two words each.
    static func wordCount(_ line: String, words: NSRegularExpression) -> Int {
        let normalized = line.precomposedStringWithCompatibilityMapping.lowercased()
        return words.numberOfMatches(in: normalized, range: NSRange(location: 0, length: (normalized as NSString).length))
    }
}
