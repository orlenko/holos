import AppKit
import Foundation
import HolosCore
import PDFKit

/// Reads local files into a `ReadableDocument` with built-in macOS APIs only.
public enum DocumentLoader {
    public static let supportedExtensions = [
        "txt", "text", "md", "markdown", "html", "htm", "pdf", "rtf", "rtfd", "docx", "doc", "odt",
    ]

    /// Unknown extensions are read as UTF-8 plain text.
    @MainActor public static func load(_ url: URL) throws -> ReadableDocument {
        let document: ReadableDocument
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            document = MarkdownReader.document(from: try utf8(url))
        case "html", "htm":
            document = HTMLReader.document(from: try Data(contentsOf: url))
        case "pdf":
            document = try PDFReader.document(url)
        case "rtf": document = try RichTextReader.document(url, type: .rtf)
        case "rtfd": document = try RichTextReader.document(url, type: .rtfd)
        case "docx": document = try RichTextReader.document(url, type: .officeOpenXML)
        case "doc": document = try RichTextReader.document(url, type: .docFormat)
        case "odt": document = try RichTextReader.document(url, type: .openDocument)
        default:
            document = PlainTextReader.document(from: try utf8(url))
        }
        guard !document.isEmpty else {
            throw HolosError.invalidInput("No readable text found in \(url.lastPathComponent).")
        }
        return document
    }

    private static func utf8(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not UTF-8 text.")
        }
        return text
    }
}

/// Paragraphs are separated by blank lines. A short first line that is not a sentence
/// becomes the title.
public enum PlainTextReader {
    public static func document(from text: String) -> ReadableDocument {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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

/// Markdown through Foundation's parser: headings become sections, emphasis and link markup
/// are dropped (link text is kept), list items and quotes become paragraphs (ordered items keep
/// their numbers: "1. Preheat"), table rows are read cell by cell, and code blocks, images, and
/// thematic breaks are skipped. YAML front matter supplies the title and author.
public enum MarkdownReader {
    public static func document(from markdown: String) -> ReadableDocument {
        let (frontMatter, body) = splitFrontMatter(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: body, options: options) else {
            let plain = PlainTextReader.document(from: body)
            return ReadableDocument(title: frontMatter["title"] ?? plain.title,
                                    author: frontMatter["author"], sections: plain.sections)
        }

        enum Kind { case heading(Int), paragraph, row }
        struct Block { var identity: Int; var kind: Kind; var text: String; var cell: Int? }
        var blocks: [Block] = []
        // List items whose number has been read: only an item's first block starts with it.
        var numberedItems = Set<Int>()
        for run in parsed.runs {
            guard run.imageURL == nil, let intent = run.presentationIntent else { continue }
            // Innermost first: [paragraph, listItem 2, orderedList, listItem 4, orderedList, ...].
            let components = intent.components
            // Code is not read aloud; a thematic break ("---", parsed as "⸻") only separates blocks.
            if components.contains(where: {
                switch $0.kind { case .codeBlock, .thematicBreak: true; default: false }
            }) { continue }
            let text = String(parsed[run.range].characters)
            var kind = Kind.paragraph
            var identity = components.first?.identity ?? -1
            var cell: Int?
            var marker: String?
            var innermostItem = true
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level): kind = .heading(level)
                case .tableCell: cell = component.identity
                case .tableRow, .tableHeaderRow:
                    kind = .row
                    identity = component.identity
                case .listItem(let ordinal):
                    // Foundation drops the "3." from the text and keeps the number here (it
                    // honors a list's start number). Bullets are not read; nested items read
                    // their own number.
                    guard innermostItem else { break }
                    innermostItem = false
                    let parent = components.indices.contains(index + 1) ? components[index + 1].kind : nil
                    if case .orderedList = parent, !numberedItems.contains(component.identity) {
                        numberedItems.insert(component.identity)
                        marker = "\(ordinal). "
                    }
                // Block quotes read as their paragraphs; lists, tables, and the document itself
                // carry nothing to read.
                default: break
                }
            }
            if let last = blocks.last, last.identity == identity {
                var merged = last
                if case .row = kind, let cell, last.cell != cell { merged.text += "; " }
                merged.text += text
                merged.cell = cell
                blocks[blocks.count - 1] = merged
            } else {
                blocks.append(Block(identity: identity, kind: kind, text: (marker ?? "") + text, cell: cell))
            }
        }

        var builder = ReadableDocument.Builder()
        for block in blocks {
            switch block.kind {
            case .heading(let level): builder.heading(block.text, level: level)
            case .paragraph, .row: builder.paragraph(block.text)
            }
        }
        return ReadableDocument(title: frontMatter["title"] ?? builder.leadingTitle,
                                author: frontMatter["author"], language: frontMatter["lang"] ?? frontMatter["language"],
                                sections: builder.sections)
    }

    /// `---` YAML front matter: simple `key: value` lines only.
    static func splitFrontMatter(_ text: String) -> ([String: String], String) {
        guard text.hasPrefix("---\n") else { return ([:], text) }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return ([:], text) }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
        return (values, lines[(end + 1)...].joined(separator: "\n"))
    }
}

/// HTML through Foundation's tidying XML parser: h1-h6 start sections, block elements become
/// paragraphs (ordered list items keep their numbers), table rows are read cell by cell, and
/// scripts, styles, navigation, forms, footers, asides, and preformatted code are skipped. Title
/// from the first h1, else `<title>`; author from `<meta name="author">`; language from
/// `<html lang>`.
public enum HTMLReader {
    static let skipped: Set<String> = [
        "script", "style", "noscript", "template", "nav", "footer", "aside", "form", "button",
        "svg", "iframe", "select", "textarea", "pre", "img", "picture", "video", "audio", "canvas",
        "head", "object", "embed", "menu",
    ]
    static let blocks: Set<String> = [
        "p", "div", "section", "article", "main", "header", "li", "ul", "ol", "dl", "dt", "dd",
        "blockquote", "figure", "figcaption", "address", "table", "thead", "tbody", "tfoot", "tr",
        "caption", "hr", "br", "body", "html", "center", "details", "summary",
    ]

    /// HTML5 elements the tidying parser does not know: it drops their tags but keeps their text,
    /// so they are removed before parsing.
    static let strippedBeforeParsing = ["nav", "footer", "aside", "template", "svg", "noscript", "script", "style"]

    public static func document(from source: Data) -> ReadableDocument {
        var plain = String(decoding: source, as: UTF8.self)
        let parsed: XMLDocument?
        if var html = String(data: source, encoding: .utf8) {
            if html.hasPrefix("\u{FEFF}") { html.removeFirst() }
            for name in strippedBeforeParsing {
                html = html.replacingOccurrences(of: "(?s)<\(name)\\b[^>]*>.*?</\(name)\\s*>", with: " ",
                                                 options: [.regularExpression, .caseInsensitive])
            }
            plain = html
            // Parsed as a string, not bytes: from bytes the tidying parser ignores the declared
            // charset, dropping non-ASCII UTF-8 without one and reading it as Windows-1252 with
            // `<meta charset="utf-8">` ("Café" -> "CafÃ©").
            parsed = try? XMLDocument(xmlString: html, options: [.documentTidyHTML])
        } else {
            // Text in another encoding is parsed as bytes, for the parser to guess.
            parsed = try? XMLDocument(data: source, options: [.documentTidyHTML])
        }
        guard let xml = parsed, let root = xml.rootElement() else {
            let text = plain.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            return PlainTextReader.document(from: text)
        }
        var walker = Walker()
        walker.walk(root)
        walker.flush()
        // local-name() matches whether or not tidying put the elements in the XHTML namespace.
        let headTitle = (try? xml.nodes(forXPath: "//*[local-name()='title']").first?.stringValue).flatMap { $0 }
        let author = (try? xml.nodes(forXPath: "//*[local-name()='meta'][@name='author']/@content")
            .first?.stringValue).flatMap { $0 }
        let language = root.attribute(forName: "lang")?.stringValue
            ?? root.attribute(forName: "xml:lang")?.stringValue
        let firstH1 = walker.builder.sections.first { $0.level == 1 }?.heading
        return ReadableDocument(title: firstH1 ?? headTitle.map(collapse), author: author,
                                language: language, sections: walker.builder.sections)
    }

    struct Walker {
        /// An `<ol>` being read: the next item's number and how items are numbered.
        struct OrderedList {
            var next: Int
            var step: Int
            var type: String
        }

        var builder = ReadableDocument.Builder()
        var inline = ""
        var row: [String]?
        /// Open lists, innermost last; nil for an unordered one.
        var lists: [OrderedList?] = []
        /// "3. " before the first text of an ordered list item.
        var marker: String?

        mutating func flush() {
            emit(collapse(inline))
            inline = ""
        }

        mutating func emit(_ text: String) {
            guard !text.isEmpty else { return }
            builder.paragraph((marker ?? "") + text)
            marker = nil
        }

        mutating func walk(_ node: XMLNode) {
            if node.kind == .text {
                inline += node.stringValue ?? ""
                return
            }
            guard node.kind == .element else { return }
            let name = (node.localName ?? node.name ?? "").lowercased()
            if Self.isSkipped(name) { return }
            if name.count == 2, name.first == "h", let level = Int(String(name.last!)), (1...6).contains(level) {
                flush()
                builder.heading(collapse(Self.text(of: node)), level: level)
                return
            }
            if name == "td" || name == "th" {
                let cell = collapse(Self.text(of: node))
                if !cell.isEmpty { row?.append(cell) }
                return
            }
            if name == "tr" {
                flush()
                row = []
                for child in node.children ?? [] { walk(child) }
                if let row, !row.isEmpty { emit(row.joined(separator: "; ")) }
                row = nil
                return
            }
            // Ordered list items keep their numbers, as the page shows them: `start`, `reversed`,
            // `type` (1, a, A, i, I), and an item's `value` are honored. Bullets are not read.
            if name == "ol" || name == "ul" || name == "menu" {
                flush()
                lists.append(name == "ol" ? Self.orderedList(node) : nil)
                for child in node.children ?? [] { walk(child) }
                flush()
                lists.removeLast()
                marker = nil
                return
            }
            if name == "li", let open = lists.last {
                flush()
                if var list = open {
                    if let value = Self.attribute("value", of: node).flatMap(Int.init) { list.next = value }
                    marker = Self.marker(list.next, type: list.type) + " "
                    list.next += list.step
                    lists[lists.count - 1] = list
                }
                for child in node.children ?? [] { walk(child) }
                flush()
                marker = nil
                return
            }
            let isBlock = HTMLReader.blocks.contains(name)
            if isBlock { flush() }
            for child in node.children ?? [] { walk(child) }
            if isBlock { flush() }
        }

        static func isSkipped(_ name: String) -> Bool { HTMLReader.skipped.contains(name) }

        static func attribute(_ name: String, of node: XMLNode) -> String? {
            (node as? XMLElement)?.attributes?.first { ($0.localName ?? $0.name)?.lowercased() == name }?
                .stringValue?.trimmingCharacters(in: .whitespaces)
        }

        static func orderedList(_ node: XMLNode) -> OrderedList {
            let reversed = attribute("reversed", of: node) != nil
            let items = (node.children ?? []).filter { ($0.localName ?? $0.name)?.lowercased() == "li" }.count
            let start = attribute("start", of: node).flatMap(Int.init) ?? (reversed ? items : 1)
            let type = attribute("type", of: node) ?? "1"
            return OrderedList(next: start, step: reversed ? -1 : 1, type: type)
        }

        /// "3.", "c.", "iii.", "C.", "III."; decimal for numbers a letter or numeral cannot show.
        static func marker(_ number: Int, type: String) -> String {
            switch type {
            case "a" where number > 0, "A" where number > 0:
                var letters = ""
                var rest = number
                while rest > 0 {
                    rest -= 1
                    letters = String(UnicodeScalar(UInt8(97 + rest % 26))) + letters
                    rest /= 26
                }
                return (type == "A" ? letters.uppercased() : letters) + "."
            case "i" where (1..<4_000).contains(number), "I" where (1..<4_000).contains(number):
                let numerals = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
                var roman = ""
                var rest = number
                for (value, symbol) in numerals {
                    while rest >= value { roman += symbol; rest -= value }
                }
                return (type == "I" ? roman.uppercased() : roman) + "."
            default:
                return "\(number)."
            }
        }

        /// Visible text of an element, without skipped descendants.
        static func text(of node: XMLNode) -> String {
            if node.kind == .text { return node.stringValue ?? "" }
            guard node.kind == .element else { return "" }
            let name = (node.localName ?? node.name ?? "").lowercased()
            if isSkipped(name) { return "" }
            let separator = HTMLReader.blocks.contains(name) ? " " : ""
            return separator + (node.children ?? []).map(text(of:)).joined() + separator
        }
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// PDF text through PDFKit, with line breaks reflowed into paragraphs.
public enum PDFReader {
    @MainActor static func document(_ url: URL) throws -> ReadableDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a readable PDF.")
        }
        guard !pdf.isLocked else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is password-protected.")
        }
        var pages: [String] = []
        for index in 0..<pdf.pageCount {
            pages.append(pdf.page(at: index)?.string ?? "")
        }
        let paragraphs = reflow(pages: pages)
        guard !paragraphs.isEmpty else {
            throw HolosError.invalidInput("\(url.lastPathComponent) has no text to read. Scanned PDFs need OCR, which is not supported.")
        }
        let attributes = pdf.documentAttributes ?? [:]
        let declared = (attributes[PDFDocumentAttribute.titleAttribute] as? String).map(cleanTitle)
        let author = attributes[PDFDocumentAttribute.authorAttribute] as? String
        return document(paragraphs: paragraphs, declaredTitle: declared, author: author)
    }

    static func document(paragraphs: [String], declaredTitle: String?, author: String?) -> ReadableDocument {
        if let declaredTitle, !declaredTitle.isEmpty {
            // The visible title under a matching metadata title is the title heading, read once.
            if paragraphs.count > 1, PlainTextReader.looksLikeTitle(paragraphs[0]),
               ReadableDocument.sameTitle(declaredTitle, paragraphs[0]) {
                return ReadableDocument(title: declaredTitle, author: author, sections: [
                    .init(heading: paragraphs[0], level: 1, paragraphs: Array(paragraphs.dropFirst())),
                ])
            }
            return ReadableDocument(title: declaredTitle, author: author, sections: [.init(paragraphs: paragraphs)])
        }
        if paragraphs.count > 1, PlainTextReader.looksLikeTitle(paragraphs[0]) {
            return ReadableDocument(title: paragraphs[0], author: author, sections: [
                .init(heading: paragraphs[0], level: 1, paragraphs: Array(paragraphs.dropFirst())),
            ])
        }
        return ReadableDocument(author: author, sections: [.init(paragraphs: paragraphs)])
    }

    /// "Microsoft Word - Report.docx" -> "Report".
    static func cleanTitle(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            for suffix in [".docx", ".doc", ".pptx", ".ppt"] where result.lowercased().hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }
        return result
    }

    /// Joins wrapped lines into paragraphs, one page's text per element of `pages`. A paragraph
    /// ends at a blank line inside a page, after a line that ends a sentence short of the margin,
    /// or after any clearly short line; at a page break it continues unless its sentence ended.
    /// Hyphenated line ends are rejoined. Page furniture (page numbers and running headers and
    /// footers) is dropped only from the top and bottom of a page; see `pageContent`.
    public static func reflow(pages: [String]) -> [String] {
        let content = pageContent(pages.map(lines(of:)))
        let lengths = content.joined().map(\.count).filter { $0 > 0 }.sorted()
        let fullLine = lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, lengths.count * 9 / 10)]
        var paragraphs: [String] = []
        var current = ""
        func end() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }
        for (pageIndex, page) in content.enumerated() {
            // A page break inside a sentence continues the paragraph.
            if pageIndex > 0, endsSentence(current) { end() }
            for line in page {
                // Leading and trailing blank lines are trimmed per page, so this blank line is
                // inside the page: a real paragraph break.
                if line.isEmpty { end(); continue }
                let length = Double(line.count), full = Double(fullLine)
                let hyphenated = line.hasSuffix("-") && line.dropLast().last?.isLetter == true
                // A short line without closing punctuation after a finished sentence is a heading.
                if endsSentence(current), length < full * 0.6, !endsSentence(line) { end() }
                if current.isEmpty {
                    current = line
                } else if current.hasSuffix("-"), current.dropLast().last?.isLetter == true,
                          line.first?.isLowercase == true {
                    current = String(current.dropLast()) + line
                } else {
                    current += " " + line
                }
                // Inside a paragraph every line but the last runs to the margin, so a short line
                // ends one (a heading, too, when it has no punctuation).
                if (endsSentence(line) && length < full * 0.75) || (length < full * 0.6 && !hyphenated) { end() }
            }
        }
        end()
        return paragraphs
    }

    /// A page's lines, trimmed, without the blank lines before its first or after its last text.
    static func lines(of page: String) -> [String] {
        let lines = page.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }),
              let last = lines.lastIndex(where: { !$0.isEmpty }) else { return [] }
        return Array(lines[first...last])
    }

    /// Removes page furniture, looking only at the first and last lines of each page (two deep,
    /// for a header above a page number):
    /// - a running header or footer: the same line, digits aside, at the same end of at least
    ///   half the pages (three or more);
    /// - "Page 3", "3 of 10", "3 / 10", "- 3 -": always;
    /// - a bare number: when it runs with the pages, that is, another page's edge number has the
    ///   same offset from its page index, or it is at the bottom and equals the page's position;
    ///   at most one per page, the bottom one first.
    /// Numbers, years, and repeated lines anywhere else on a page are text and are kept.
    static func pageContent(_ pages: [[String]]) -> [[String]] {
        var pages = pages
        let threshold = pages.count >= 3 ? max(3, (pages.count + 1) / 2) : Int.max
        var numbered = Set<Int>()
        for _ in 0..<2 {
            var headers: [String: Int] = [:]
            var footers: [String: Int] = [:]
            var numberOffsets: [Int: Int] = [:]
            for (index, page) in pages.enumerated() {
                guard let first = page.first, let last = page.last else { continue }
                headers[furnitureKey(first), default: 0] += 1
                footers[furnitureKey(last), default: 0] += 1
                for line in Set([first, last]) {
                    if let number = bareNumber(line) { numberOffsets[number - index, default: 0] += 1 }
                }
            }
            for index in pages.indices {
                var page = pages[index]
                guard let first = page.first, let last = page.last else { continue }
                func isFurniture(_ line: String, bottom: Bool) -> Bool {
                    let isNumber = bareNumber(line) != nil || isPageLabel(line)
                    var furniture = (bottom ? footers : headers)[furnitureKey(line), default: 0] >= threshold
                        || isPageLabel(line)
                    if !furniture, !numbered.contains(index), let number = bareNumber(line) {
                        furniture = numberOffsets[number - index, default: 0] >= 2 || (bottom && number == index + 1)
                    }
                    if furniture && isNumber { numbered.insert(index) }
                    return furniture
                }
                let bottom = isFurniture(last, bottom: true)
                let top = isFurniture(first, bottom: false)
                if page.count == 1 {
                    if bottom || top { page = [] }
                } else {
                    if bottom { page.removeLast() }
                    if top { page.removeFirst() }
                }
                pages[index] = lines(of: page.joined(separator: "\n"))
            }
        }
        return pages
    }

    static func furnitureKey(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func bareNumber(_ line: String) -> Int? {
        guard (1...4).contains(line.count), line.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(line)
    }

    /// "Page 3", "page 3 of 10", "3 of 10", "3 / 10", "- 3 -".
    static func isPageLabel(_ line: String) -> Bool {
        line.range(of: #"^(page\s+\d{1,4}(\s+(of|/)\s+\d{1,4})?|\d{1,4}\s+(of|/)\s+\d{1,4}|[-–—]\s*\d{1,4}\s*[-–—])$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?:\"”’)".contains(last)
    }
}

/// RTF, RTFD, Word, and OpenDocument text through AppKit's document readers. Paragraphs that are
/// marked as headings, or are short, unpunctuated, and set larger or bold, become headings.
/// Numbered list items keep their numbers: the Word readers leave them in the text ("\t1.\tItem"),
/// while the RTF and OpenDocument readers move them into the paragraph's text list, from which
/// they are put back.
public enum RichTextReader {
    @MainActor static func document(_ url: URL, type: NSAttributedString.DocumentType) throws -> ReadableDocument {
        var attributes: NSDictionary?
        let text: NSAttributedString
        do {
            text = try NSAttributedString(url: url, options: [.documentType: type],
                                          documentAttributes: &attributes)
        } catch {
            throw HolosError.invalidInput("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let values = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        return document(from: text, title: values[.title] as? String, author: values[.author] as? String)
    }

    public static func document(from text: NSAttributedString, title: String?, author: String?) -> ReadableDocument {
        let string = text.string as NSString
        var paragraphs: [(text: String, size: CGFloat, bold: Bool, level: Int, listed: Bool)] = []
        var sizes: [CGFloat: Int] = [:]
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { substring, range, _, _ in
            guard var substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let list = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textLists.last
            // The Word readers keep the marker between tabs instead of a text list.
            let markedInText = substring.range(of: #"^\t[^\s]{1,8}\t"#, options: .regularExpression) != nil
            if let list {
                substring = numbered(substring, marker: list.marker(forItemNumber: text.itemNumber(in: list, at: range.location)))
            }
            var size: CGFloat = 0
            var bold = true
            var level = 0
            text.enumerateAttributes(in: range) { attributes, run, _ in
                if let font = attributes[.font] as? NSFont {
                    size = max(size, font.pointSize)
                    if !font.fontDescriptor.symbolicTraits.contains(.bold) { bold = false }
                    sizes[font.pointSize, default: 0] += run.length
                } else {
                    bold = false
                }
                if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.headerLevel > 0 {
                    level = style.headerLevel
                }
            }
            paragraphs.append((substring, size, bold, level, list != nil || markedInText))
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 0
        var builder = ReadableDocument.Builder()
        for paragraph in paragraphs {
            var level = paragraph.level
            // A list item is never taken for a heading, however it is set.
            if level == 0, !paragraph.listed, PlainTextReader.looksLikeTitle(paragraph.text), body > 0 {
                if paragraph.size >= body * 1.5 { level = 1 }
                else if paragraph.size >= body + 2 || (paragraph.bold && paragraph.size >= body) { level = 2 }
            }
            if level > 0 { builder.heading(paragraph.text, level: level) }
            else { builder.paragraph(paragraph.text) }
        }
        let declared = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadableDocument(title: declared?.isEmpty == false ? declared : builder.leadingTitle,
                                author: author, sections: builder.sections)
    }

    /// A list item's text starting with its number ("3. Serve"). Bullets are not read, and a
    /// number the text already starts with is not added again.
    static func numbered(_ text: String, marker: String) -> String {
        let marker = marker.trimmingCharacters(in: .whitespaces)
        guard marker.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        let punctuation = CharacterSet(charactersIn: ".)(")
        let body = text.trimmingCharacters(in: .whitespaces)
        let first = body.prefix { !$0.isWhitespace }.trimmingCharacters(in: punctuation)
        if first == marker.trimmingCharacters(in: punctuation) { return text }
        let spoken = marker.last.map { $0.isLetter || $0.isNumber } == true ? marker + "." : marker
        return spoken + " " + body
    }
}
