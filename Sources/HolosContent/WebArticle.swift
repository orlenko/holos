import Foundation

/// A web article reduced to what is read aloud: its metadata and, in page order, its headings and paragraphs.
///
/// List items, quotations, and definition terms each become a paragraph. Code blocks (`<pre>`), tables, figures,
/// captions, images, media, forms, bracketed marks such as `[1]` or `[edit]`, and back-matter sections (references,
/// notes, see also, external links, further reading) are left out; inline code inside a paragraph is kept as text.
public struct WebArticle: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)

        public var text: String {
            switch self {
            case .heading(_, let text), .paragraph(let text): text
            }
        }
    }

    /// The address the page ended up at, after redirects.
    public let url: URL
    public let title: String
    /// The author line as the page gives it, for example "By Jane Doe".
    public let byline: String?
    public let siteName: String?
    /// The page's language tag, when it declares one.
    public let language: String?
    public let blocks: [Block]

    public init(url: URL, title: String, byline: String?, siteName: String?, language: String?, blocks: [Block]) {
        self.url = url
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.language = language
        self.blocks = blocks
    }

    /// Words in the headings and paragraphs, not counting the title and byline.
    public var wordCount: Int { blocks.reduce(0) { $0 + Self.words(in: $1.text) } }

    /// The text to speak: the title, the byline, then every heading and paragraph, each separated by a blank line.
    public var spokenText: String {
        var parts = [title]
        if let byline {
            parts.append(byline.lowercased().hasPrefix("by ") ? byline : "By \(byline)")
        }
        parts += blocks.map(\.text)
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Builds an article from raw extracted pieces: collapses whitespace, drops empty blocks, and drops a leading
    /// heading that repeats the title. `level` 0 marks a paragraph, 1 through 6 a heading.
    static func assemble(url: URL, title: String?, byline: String?, siteName: String?, language: String?,
                         raw: [(level: Int, text: String)]) -> WebArticle {
        var blocks: [Block] = raw.compactMap { item in
            let text = normalized(item.text)
            guard !text.isEmpty, !isBracketMark(text) else { return nil }
            return (1...6).contains(item.level) ? .heading(level: item.level, text: text) : .paragraph(text)
        }
        let cleanTitle = normalized(title ?? "")
        let resolvedTitle = cleanTitle.isEmpty ? (url.host() ?? url.absoluteString) : cleanTitle
        if case .heading(_, let text)? = blocks.first,
           text.caseInsensitiveCompare(resolvedTitle) == .orderedSame {
            blocks.removeFirst()
        }
        return WebArticle(url: url, title: resolvedTitle, byline: nonEmpty(byline), siteName: nonEmpty(siteName),
                          language: nonEmpty(language), blocks: blocks)
    }

    /// Collapses every run of whitespace (including no-break spaces) to one space, removes zero-width characters,
    /// and trims the ends.
    static func normalized(_ text: String) -> String {
        let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars where !invisible.contains(scalar) {
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// A block that is only a short bracketed mark, such as Wikipedia's "[edit]" links or a stray "[1]".
    private static func isBracketMark(_ text: String) -> Bool {
        text.count <= 24 && text.hasPrefix("[") && text.hasSuffix("]") && !text.dropFirst().dropLast().contains("]")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = normalized(text)
        return clean.isEmpty ? nil : clean
    }

    private static func words(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
