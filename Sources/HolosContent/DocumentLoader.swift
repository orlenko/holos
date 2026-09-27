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
/// are dropped (link text is kept), lists and quotes become paragraphs, table rows are read
/// cell by cell, and code blocks and images are skipped. YAML front matter supplies the title
/// and author.
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
        for run in parsed.runs {
            guard run.imageURL == nil, let intent = run.presentationIntent else { continue }
            let components = intent.components
            if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) { continue }
            let text = String(parsed[run.range].characters)
            var kind = Kind.paragraph
            var identity = components.first?.identity ?? -1
            var cell: Int?
            for component in components {
                switch component.kind {
                case .header(let level): kind = .heading(level)
                case .tableCell: cell = component.identity
                case .tableRow, .tableHeaderRow:
                    kind = .row
                    identity = component.identity
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
                blocks.append(Block(identity: identity, kind: kind, text: text, cell: cell))
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
/// paragraphs, and scripts, styles, navigation, forms, footers, asides, and preformatted code are
/// skipped. Title from the first h1, else `<title>`; author from `<meta name="author">`; language
/// from `<html lang>`.
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
        var data = source
        // Text in another encoding is parsed as is: the parser follows its declared charset.
        if var html = String(data: source, encoding: .utf8) {
            for name in strippedBeforeParsing {
                html = html.replacingOccurrences(of: "(?s)<\(name)\\b[^>]*>.*?</\(name)\\s*>", with: " ",
                                                 options: [.regularExpression, .caseInsensitive])
            }
            data = Data(html.utf8)
        }
        guard let xml = try? XMLDocument(data: data, options: [.documentTidyHTML]),
              let root = xml.rootElement() else {
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
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
        var builder = ReadableDocument.Builder()
        var inline = ""
        var row: [String]?

        mutating func flush() {
            builder.paragraph(collapse(inline))
            inline = ""
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
                if let row, !row.isEmpty { builder.paragraph(row.joined(separator: "; ")) }
                row = nil
                return
            }
            let isBlock = HTMLReader.blocks.contains(name)
            if isBlock { flush() }
            for child in node.children ?? [] { walk(child) }
            if isBlock { flush() }
        }

        static func isSkipped(_ name: String) -> Bool { HTMLReader.skipped.contains(name) }

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

    /// Joins wrapped lines into paragraphs. A paragraph ends at a blank line, after a line that
    /// ends a sentence short of the margin, or after any clearly short line. Hyphenated line ends
    /// are rejoined; lines that are only page numbers are dropped.
    public static func reflow(pages: [String]) -> [String] {
        let lines = pages.flatMap { page in
            page.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) } + [""]
        }.filter { !isPageNumber($0) }
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        let fullLine = lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, lengths.count * 9 / 10)]
        var paragraphs: [String] = []
        var current = ""
        func end() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                // A page break inside a sentence continues the paragraph.
                let pageBreak = index > 0 && index + 1 < lines.count && !lines[index + 1].isEmpty
                if !(pageBreak && !endsSentence(current)) { end() }
                continue
            }
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
        end()
        return paragraphs
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?:\"”’)".contains(last)
    }

    static func isPageNumber(_ line: String) -> Bool {
        line.range(of: #"^(page\s+)?\d{1,4}(\s+(of|/)\s+\d{1,4})?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// RTF, RTFD, Word, and OpenDocument text through AppKit's document readers. Paragraphs that are
/// marked as headings, or are short, unpunctuated, and set larger or bold, become headings.
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
        var paragraphs: [(text: String, size: CGFloat, bold: Bool, level: Int)] = []
        var sizes: [CGFloat: Int] = [:]
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { substring, range, _, _ in
            guard let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
            paragraphs.append((substring, size, bold, level))
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 0
        var builder = ReadableDocument.Builder()
        for paragraph in paragraphs {
            var level = paragraph.level
            if level == 0, PlainTextReader.looksLikeTitle(paragraph.text), body > 0 {
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
}
