import Foundation

/// Paragraphs are separated by blank lines. A short first line that is not a sentence
/// becomes the title.
public enum PlainTextReader {
    public static func document(from text: String) -> ReadableDocument {
        let paragraphs = DocumentText.normalized(text)
            .components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.joined(separator: "\n") }
        guard let first = paragraphs.first else { return ReadableDocument(sections: []) }
        if paragraphs.count > 1, looksLikeTitle(first) {
            return ReadableDocument(title: first, sections: [
                .init(heading: first, level: 1, paragraphs: Array(paragraphs.dropFirst())),
            ])
        }
        return ReadableDocument(sections: [.init(paragraphs: paragraphs)])
    }

    /// One line with a letter or digit, at most 120 characters, not ending like a sentence.
    static func looksLikeTitle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains("\n"),
              trimmed.contains(where: { $0.isLetter || $0.isNumber }),
              let last = trimmed.last else { return false }
        return !".,;:!?".contains(last)
    }
}

extension ReadableDocument {
    /// The words a title made from a selection's first words keeps.
    static let selectionTitleWords = 8

    /// Text selected in another app, as a reading reads it: paragraphs as in a plain text file (`PlainTextReader`),
    /// titled by its first line when that looks like a title, else by its first words. Nil when it has no text.
    public static func selection(_ text: String) -> ReadableDocument? {
        let document = PlainTextReader.document(from: text)
        guard !document.isEmpty else { return nil }
        if document.title != nil { return document }
        let words = document.plainText.split(whereSeparator: \.isWhitespace)
        var title = words.prefix(selectionTitleWords).joined(separator: " ")
        if words.count > selectionTitleWords { title += "…" }
        return ReadableDocument(title: title, language: document.language, sections: document.sections)
    }
}
