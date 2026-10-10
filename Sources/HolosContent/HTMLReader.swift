import Foundation

/// HTML through Foundation's tidying XML parser: h1-h6 start sections, block elements become
/// paragraphs (ordered list items keep their numbers), table rows are read cell by cell, and
/// scripts, styles, templates, navigation, forms, footers, asides, media, preformatted code, and
/// hidden elements (`hidden`, `aria-hidden="true"`, inline `display: none`) are skipped with
/// everything inside them; of a closed `<details>`, only its summary is read. Title from the
/// first h1, else `<title>`; author and language from the page's metadata (see `Metadata`).
///
/// Every page takes the same path: its bytes are decoded to text (see `decode`), HTML5 elements
/// are renamed so the parser keeps them (see `prepared`), the text is parsed once, and the tree
/// is walked, leaving out skipped elements.
public enum HTMLReader {
    /// Preformatted code is `pre` and its legacy forms `xmp`, `listing`, and `plaintext`.
    static let skipped: Set<String> = [
        "script", "style", "noscript", "template", "nav", "footer", "aside", "form", "button",
        "svg", "math", "iframe", "select", "textarea", "pre", "xmp", "listing", "plaintext", "img", "picture",
        "video", "audio", "canvas", "head", "object", "embed", "datalist",
    ]
    static let blocks: Set<String> = [
        "p", "div", "section", "article", "main", "header", "li", "ul", "ol", "dl", "dt", "dd",
        "blockquote", "figure", "figcaption", "address", "table", "thead", "tbody", "tfoot", "tr",
        "caption", "hr", "br", "body", "html", "center", "details", "summary", "hgroup", "search", "dialog",
    ]

    public static func document(from source: Data) -> ReadableDocument {
        let nameAttribute = originalNameAttribute()
        let html = prepared(decode(source), nameAttribute: nameAttribute)
        // The parser gives up on some fragments without `<html>` ("<p>Text"); wrapped, they parse.
        guard let xml = parse(html) ?? parse("<html><body>" + html + "</body></html>"),
              let root = xml.rootElement() else { return ReadableDocument(sections: []) }
        var walker = Walker(nameAttribute: nameAttribute)
        walker.walk(root)
        walker.flush()
        let metadata = Metadata(root)
        let firstH1 = walker.builder.sections.first { $0.level == 1 }?.heading
        return ReadableDocument(title: firstH1 ?? metadata.title.map(collapse), author: metadata.author,
                                language: metadata.language, sections: walker.builder.sections)
    }

    /// Parsed from a string, never bytes: from bytes the tidying parser ignores the declared
    /// charset, dropping non-ASCII UTF-8 without one and reading it as Windows-1252 with
    /// `<meta charset="utf-8">` ("Café" -> "CafÃ©"). From a string it ignores any declaration.
    private static func parse(_ html: String) -> XMLDocument? {
        try? XMLDocument(xmlString: html, options: [.documentTidyHTML])
    }

    /// The page's `<title>`, author, and language. HTML element names, attribute names, and
    /// metadata names are ASCII case-insensitive (`<META NAME="Author">`, `<html LANG="fr">`), so
    /// every one is compared lowercased, whether or not tidying put the elements in the XHTML
    /// namespace. The author is the first non-empty `<meta name>` of "author", then Dublin
    /// Core's "dc.creator" or "dcterms.creator". (`article:author` is an Open Graph profile URL,
    /// not a name, so it is not read.)
    struct Metadata {
        static let authorNames = ["author", "dc.creator", "dcterms.creator"]

        var title: String?
        var author: String?
        var language: String?

        init(_ root: XMLElement) {
            language = Self.nonEmpty(Walker.attribute("lang", of: root, qualified: "lang")
                ?? Walker.attribute("lang", of: root))
            var authors: [String: String] = [:]
            var pending: [XMLNode] = [root]
            while let node = pending.popLast() {
                guard node.kind == .element else { continue }
                switch (node.localName ?? node.name ?? "").lowercased() {
                case "title" where title == nil:
                    title = node.stringValue
                case "meta":
                    if let name = Walker.attribute("name", of: node)?.lowercased(), Self.authorNames.contains(name),
                       authors[name] == nil, let content = Self.nonEmpty(Walker.attribute("content", of: node)) {
                        authors[name] = content
                    }
                default: break
                }
                // Children in document order: the stack takes them last to first.
                pending += (node.children ?? []).reversed()
            }
            author = Self.authorNames.lazy.compactMap { authors[$0] }.first
        }

        private static func nonEmpty(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
