import Foundation

/// Removes hesitation sounds ("um", "uh", "ah", "erm", "hmm") and the commas the recognizer puts around
/// them. Each removal depends only on text up to and including the filler, so cleaning a growing
/// transcript keeps earlier output a prefix of later output.
public enum FillerWords {
    // "mm", "hm", and "er" are left alone: they collide with units and abbreviations ("5 mm", "ER").
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        // Identifier, address, query, and assignment punctuation counts as part of the token
        // ("um@example.com", "foo_um_bar", "um.example.com", "x=um", "?q=um&a", "um:8080"); a period or
        // colon followed by a space still ends prose.
        pattern: "(?<![\\p{L}\\p{N}'’@._/\\\\#=:&+-])(?:um+|uhm*|uh+|erm|ah+|hm{2,})(?![\\p{L}\\p{N}'’@_/\\\\#=&+-]|[.:][\\p{L}\\p{N}])",
        options: [.caseInsensitive])

    private static let openers: Set<Character> = ["“", "‘", "\"", "'", "(", "[", "{", "«"]

    public static func remove(from text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        var capitalizeNext = false
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let found = Range(match.range, in: text) else { continue }
            append(text[cursor..<found.lowerBound], to: &output, capitalizeNext: &capitalizeNext)
            // Drop the space and one comma the recognizer placed before the filler.
            while output.last?.isWhitespace == true { output.removeLast() }
            if output.last == "," { output.removeLast() }
            while output.last?.isWhitespace == true { output.removeLast() }
            // Capitalize what follows only when the filler itself began a sentence, looking past opening
            // quotes and brackets ("“Um, hello" → "“Hello").
            var context = output[...]
            while let last = context.last, openers.contains(last) { context = context.dropLast() }
            while context.last?.isWhitespace == true { context = context.dropLast() }
            let beganSentence = context.last.map { ".!?…".contains($0) } ?? true

            var rest = found.upperBound
            if rest < text.endIndex {
                let mark = text[rest]
                if mark == "," {
                    rest = text.index(after: rest)
                } else if ".!?…".contains(mark) {
                    // Take the whole run ("...", "?!") as one mark.
                    var end = rest
                    while end < text.endIndex, ".!?…".contains(text[end]) { end = text.index(after: end) }
                    // Keep the mark when it ends a sentence that had words before the filler.
                    if let last = output.last, !".!?…".contains(last) { output += text[rest..<end] }
                    rest = end
                }
            }
            while rest < text.endIndex, text[rest].isWhitespace { rest = text.index(after: rest) }
            if rest < text.endIndex, let last = output.last, !openers.contains(last),
               !",.;:!?…)”’\"".contains(text[rest]) { output.append(" ") }
            capitalizeNext = beganSentence
            cursor = rest
        }
        append(text[cursor...], to: &output, capitalizeNext: &capitalizeNext)
        return output
    }

    /// For text still growing while the user speaks: also holds back a trailing comma, which a filler
    /// in the next words may still remove ("I think," then "um, that works").
    public static func removeWithholdingTrailingComma(from text: String) -> String {
        var cleaned = remove(from: text)
        while cleaned.last?.isWhitespace == true { cleaned.removeLast() }
        if cleaned.last == "," { cleaned.removeLast() }
        return cleaned
    }

    private static func append(_ piece: Substring, to output: inout String, capitalizeNext: inout Bool) {
        guard !piece.isEmpty else { return }
        // Look past opening quotes and brackets: "Um, “hello”" → "“Hello”".
        if capitalizeNext, let letter = piece.firstIndex(where: { !openers.contains($0) }), piece[letter].isLetter {
            output += piece[..<letter] + piece[letter].uppercased() + piece[piece.index(after: letter)...]
        } else {
            output += piece
        }
        capitalizeNext = false
    }
}
