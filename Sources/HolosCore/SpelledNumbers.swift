import Foundation

/// Writes the numbers of a text out in words, in English or French, so that two texts saying the same numbers read
/// alike whichever way each writes them: "3.05" and "three point zero five", "1 500" and "mille cinq cents".
///
/// Contract: each run of digits in `text`, with a minus sign before it and the language's grouping separators and
/// decimal mark inside it, is parsed with that language's `NumberFormatter` and replaced by the formatter's
/// `.spellOut` words (with a space on each side). A run the formatter cannot parse ("1,2,3", "1.500" in French) is
/// spelled one digit group at a time. Everything else is kept as written; ordinals keep their suffix as a word of its
/// own ("1st" gives "one st").
public enum SpelledNumbers {
    /// A digit run: a minus sign only at the start of a word (so "1990-2000" is two runs, not a negative), digits,
    /// and grouping separators or decimal marks between digits (no plain space: "10 200" is two numbers, but French
    /// groups of three are joined first, `frenchGroups`).
    private static let digitRun = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])[-−]?\p{Nd}(?:[\p{Nd}.,'   ]*\p{Nd})?"#)

    /// French groups thousands with a space, an ordinary one too: "1 234 567" is one number when every group after the
    /// first has exactly three digits (and the first one to three).
    private static let frenchGroups = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])\p{Nd}{1,3}(?:[ \u00A0\u202F]\p{Nd}{3})+(?!\p{N})"#)

    /// `text` with the spaces inside French grouped numbers taken out.
    private static func joiningFrenchGroups(_ text: String) -> String {
        var result = ""
        var rest = text.startIndex
        for match in frenchGroups.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[rest..<range.lowerBound] + text[range].filter(\.isNumber)
            rest = range.upperBound
        }
        return result + text[rest...]
    }

    public static func spellingOut(_ text: String, language: String) -> String {
        let french = language.lowercased().hasPrefix("fr")
        let text = french ? joiningFrenchGroups(text) : text
        let parser = NumberFormatter()
        parser.locale = Locale(identifier: french ? "fr_FR" : "en_US")
        parser.numberStyle = .decimal
        parser.generatesDecimalNumbers = true
        let speller = NumberFormatter()
        speller.locale = Locale(identifier: french ? "fr" : "en")
        speller.numberStyle = .spellOut
        // Very large numbers come back in digits: spelled one digit at a time instead.
        func words(_ number: NSNumber) -> String? {
            speller.string(from: number).flatMap { $0.contains(where: \.isNumber) ? nil : $0 }
        }
        func group(_ digits: Substring) -> String {
            words(NSDecimalNumber(string: String(digits)))
                ?? digits.compactMap { $0.wholeNumberValue.flatMap { words(NSNumber(value: $0)) } }
                    .joined(separator: " ")
        }
        var result = ""
        var rest = text.startIndex
        for match in digitRun.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let run = text[range].replacingOccurrences(of: "\u{2212}", with: "-")
            let spelled = parser.number(from: run).flatMap(words)
                ?? run.split(whereSeparator: { !$0.isNumber }).map(group).joined(separator: " ")
            result += text[rest..<range.lowerBound] + " " + spelled + " "
            rest = range.upperBound
        }
        return result + text[rest...]
    }
}
