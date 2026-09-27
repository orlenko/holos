import Foundation

/// A web article reduced to what is read aloud: its metadata and, in page order, its headings and paragraphs.
///
/// List items, quotations, and definition terms each become a paragraph. Code blocks (`<pre>`), tables, figures,
/// captions, images, media, forms, bracketed marks such as `[1]` or `[edit]`, and back-matter sections (references,
/// notes, see also, external links, further reading) are left out; inline code inside a paragraph is kept as text.
///
/// Every text an article holds comes from an untrusted page, so it is made safe to print when the article is made
/// (see `sanitized(_:)`): the title, byline, site name, language, and each heading and paragraph. `address` is the
/// page's address made safe the same way.
public struct WebArticle: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)

        public var text: String {
            switch self {
            case .heading(_, let text), .paragraph(let text): text
            }
        }

        fileprivate var sanitized: Block {
            switch self {
            case .heading(let level, let text): .heading(level: level, text: WebArticle.sanitized(text))
            case .paragraph(let text): .paragraph(WebArticle.sanitized(text))
            }
        }
    }

    /// The address of the document that was read (after redirects).
    public let url: URL
    public let title: String
    /// The author line as the page gives it, for example "By Jane Doe".
    public let byline: String?
    public let siteName: String?
    /// The page's language tag, when it declares one.
    public let language: String?
    public let blocks: [Block]

    /// Sanitizes every text (see `sanitized(_:)`); nothing else is changed.
    public init(url: URL, title: String, byline: String?, siteName: String?, language: String?, blocks: [Block]) {
        self.url = url
        self.title = Self.sanitized(title)
        self.byline = byline.map(Self.sanitized)
        self.siteName = siteName.map(Self.sanitized)
        self.language = language.map(Self.sanitized)
        self.blocks = blocks.map(\.sanitized)
    }

    /// `url` as text that is safe to print.
    public var address: String { Self.address(url) }

    static func address(_ url: URL) -> String { sanitized(url.absoluteString) }

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

    /// Builds an article from raw extracted pieces: sanitizes every text, drops blocks with no letters or digits (a
    /// permalink's "#", a "* * *" break) and bracketed marks, and drops a leading heading that repeats the title.
    /// `level` 0 marks a paragraph, 1 through 6 a heading.
    static func assemble(url: URL, title: String?, byline: String?, siteName: String?, language: String?,
                         raw: [(level: Int, text: String)]) -> WebArticle {
        var blocks: [Block] = raw.compactMap { item in
            let text = sanitized(item.text)
            let readable = text.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            guard readable, !isBracketMark(text) else { return nil }
            return (1...6).contains(item.level) ? .heading(level: item.level, text: text) : .paragraph(text)
        }
        let cleanTitle = sanitized(title ?? "")
        let resolvedTitle = cleanTitle.isEmpty ? sanitized(url.host() ?? url.absoluteString) : cleanTitle
        if case .heading(_, let text)? = blocks.first,
           text.caseInsensitiveCompare(resolvedTitle) == .orderedSame {
            blocks.removeFirst()
        }
        return WebArticle(url: url, title: resolvedTitle, byline: nonEmpty(byline), siteName: nonEmpty(siteName),
                          language: nonEmpty(language), blocks: blocks)
    }

    /// Makes untrusted text safe to print on a terminal and to speak: every run of whitespace (tabs, line and
    /// paragraph separators, no-break spaces, NEL) becomes one space; control characters (C0, DEL, C1, so no
    /// escape sequence survives), format characters (bidirectional overrides, embeddings, isolates and marks,
    /// zero-width characters, the soft hyphen, the byte-order mark, tag characters), and noncharacters are removed;
    /// the ends are trimmed.
    public static func sanitized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace {
                pendingSpace = !result.isEmpty
            } else if properties.generalCategory == .control || properties.generalCategory == .format
                        || properties.isNoncharacterCodePoint {
                continue
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// A block that is only short bracketed marks, one or several with optional separators: Wikipedia's "[edit]"
    /// links, a stray "[1]", or a group such as "[1][2]", "[1], [2]", or "[edit] [a][note 3]".
    private static func isBracketMark(_ text: String) -> Bool {
        text.wholeMatch(of: /\[[^\[\]]{0,22}\](?:\s*[,;–—-]?\s*\[[^\[\]]{0,22}\])*/) != nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = sanitized(text)
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
