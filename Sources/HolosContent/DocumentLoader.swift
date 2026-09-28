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
        guard let text = DocumentText.decode(try Data(contentsOf: url)) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not UTF-8 text.")
        }
        return text
    }
}

/// Bytes of a text file (or stdin) as a string: UTF-8, or UTF-16 or UTF-32 when a byte order
/// mark says so (Windows Notepad saves "Unicode" as UTF-16 with one). Nil for anything else.
/// One leading byte order mark is dropped, so it never hides YAML front matter or ends up in a
/// title, and every line ends in LF (see `withLFLineEndings`).
public enum DocumentText {
    public static func decode(_ data: Data) -> String? {
        let text: String?
        if let (length, encoding) = byteOrderMark(data) {
            text = decode(data.dropFirst(length), as: encoding)
        } else {
            text = decode(data, as: .utf8)
        }
        return text.map(withLFLineEndings)
    }

    /// `text` with Windows (CRLF) and classic Mac (CR) line endings made LF, so front matter,
    /// Markdown, and paragraph breaks are found whichever system saved the file. The one place
    /// line endings are normalized: the decoders (this one and `HTMLReader.decode`) apply it
    /// before any parsing, and so do the readers that take a string (see `normalized`).
    public static func withLFLineEndings(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// A string as the text readers take it (it may not come from `decode`): without one leading
    /// U+FEFF, and with LF line endings.
    public static func normalized(_ text: String) -> String {
        withLFLineEndings(withoutByteOrderMark(text))
    }

    /// The Unicode encoding a leading byte order mark names, and the mark's length in bytes.
    static func byteOrderMark(_ data: Data) -> (length: Int, encoding: String.Encoding)? {
        let marks: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian), ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian), ([0xEF, 0xBB, 0xBF], .utf8),
        ]
        let head = [UInt8](data.prefix(4))
        return marks.first { head.starts(with: $0.0) }.map { ($0.0.count, $0.1) }
    }

    /// `data` in `encoding`, or nil when it is not valid in it.
    static func decode(_ data: Data, as encoding: String.Encoding) -> String? {
        // Validated as is: Foundation's UTF-8 decoding drops a leading byte order mark.
        if encoding == .utf8 { return String(validating: data, as: UTF8.self) }
        return String(data: data, encoding: encoding)
    }

    /// `text` without one leading U+FEFF.
    public static func withoutByteOrderMark(_ text: String) -> String {
        guard text.unicodeScalars.first == "\u{FEFF}" else { return text }
        return String(text.unicodeScalars.dropFirst())
    }
}

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

/// Markdown through Foundation's parser: headings become sections, emphasis and link markup
/// are dropped (link text is kept), list items and quotes become paragraphs (ordered items keep
/// their numbers: "1. Preheat"), table rows are read cell by cell, and code blocks, images, and
/// thematic breaks are skipped. YAML front matter supplies the title and author.
public enum MarkdownReader {
    public static func document(from markdown: String) -> ReadableDocument {
        let (frontMatter, body) = splitFrontMatter(DocumentText.normalized(markdown))
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
/// scripts, styles, templates, navigation, forms, footers, asides, media, preformatted code, and
/// hidden elements (`hidden`, `aria-hidden="true"`, inline `display: none`) are skipped with
/// everything inside them. Title from the first h1, else `<title>`; author and language from the
/// page's metadata (see `Metadata`).
///
/// Every page takes the same path: its bytes are decoded to text (see `decode`), HTML5 elements
/// are renamed so the parser keeps them (see `prepared`), the text is parsed once, and the tree
/// is walked, leaving out skipped elements.
public enum HTMLReader {
    static let skipped: Set<String> = [
        "script", "style", "noscript", "template", "nav", "footer", "aside", "form", "button",
        "svg", "math", "iframe", "select", "textarea", "pre", "img", "picture", "video", "audio", "canvas",
        "head", "object", "embed", "datalist",
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

    // MARK: Encoding

    /// A page's bytes as text, the encoding picked as a browser picks it:
    /// 1. a byte order mark: UTF-8, UTF-16, or UTF-32;
    /// 2. else the charset declared in the first 1024 bytes, by `<meta charset>` or
    ///    `<meta http-equiv="Content-Type" content="…; charset=…">` (any ASCII case), outside
    ///    comments and scripts (see `CharsetPrescan`). As in
    ///    browsers, ISO-8859-1 and ASCII mean Windows-1252, and UTF-16 or UTF-32 without a mark
    ///    means UTF-8;
    /// 3. else UTF-8 when the bytes are valid UTF-8;
    /// 4. else Windows-1252, HTML's default.
    /// A declared UTF-8 page with invalid bytes is read as UTF-8 with replacement characters; bytes
    /// invalid in another declared encoding fall through to 3 and 4. One leading U+FEFF is dropped,
    /// and line endings are made LF (see `DocumentText.normalized`).
    static func decode(_ data: Data) -> String {
        DocumentText.normalized(decodeKeepingMark(data))
    }

    private static func decodeKeepingMark(_ data: Data) -> String {
        if let (length, encoding) = DocumentText.byteOrderMark(data),
           let text = DocumentText.decode(data.dropFirst(length), as: encoding) {
            return text
        }
        if let declared = declaredEncoding(data) {
            if declared == .windowsCP1252 { return windows1252(data) }
            if let text = DocumentText.decode(data, as: declared) { return text }
            if declared == .utf8 { return String(decoding: data, as: UTF8.self) }
        }
        return DocumentText.decode(data, as: .utf8) ?? windows1252(data)
    }

    /// Characters for bytes 0x80-0x9F in Windows-1252; the five it leaves undefined stand for
    /// themselves, as in browsers. Every other byte is the code point of the same number.
    private static let windows1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039,
        0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    /// `data` in Windows-1252, which decodes every byte (Foundation's decoder fails on the five
    /// undefined ones).
    static func windows1252(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in data {
            let value = (0x80...0x9F).contains(byte) ? windows1252High[Int(byte) - 0x80] : UInt32(byte)
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }

    /// The encoding the first `<meta>` in the first 1024 bytes declares that Foundation knows, found
    /// as HTML's prescan finds it (see `CharsetPrescan`).
    static func declaredEncoding(_ data: Data) -> String.Encoding? {
        var prescan = CharsetPrescan(bytes: Array(data.prefix(1024)))
        return prescan.encoding()
    }

    /// HTML's tokenizer for one tag, over a page's bytes: the one reading of tag names and
    /// attributes that both the charset prescan (`CharsetPrescan`) and `prepared` use, so the two
    /// never disagree on where a name or a tag ends.
    /// - A tag name starts with the letter after `<` or `</` and ends at a space, `/`, or `>`, so
    ///   `<script/>` is a script (HTML ignores the slash on it).
    /// - Attributes follow HTML's "get an attribute": spaces and slashes before one are skipped;
    ///   its name ends at `=`, a space, `/`, or `>`; its value, after `=` and optional spaces, is
    ///   double-quoted, single-quoted (a `>` inside does not end the tag), or unquoted up to a
    ///   space or `>` (`href=a/>` keeps its slash).
    struct TagScanner {
        /// One attribute, as byte ranges of the page.
        struct Attribute {
            var name: Range<Int>
            /// Without its quotes; empty when the attribute has no value.
            var value: Range<Int>
            var unquoted: Bool
        }

        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let equals = UInt8(ascii: "=")

        let bytes: [UInt8]
        var position: Int

        /// Whether `byte` ends a tag name: a space, `/`, or `>`.
        static func isNameEnd(_ byte: UInt8) -> Bool {
            HTMLReader.isSpace(byte) || byte == slash || byte == greaterThan
        }

        /// At `<` or `</` and a letter: the tag's name, lowercased, and whether it ends an element,
        /// with `position` moved past the name. Nil (and `position` kept) at anything else.
        mutating func tagName() -> (name: String, closing: Bool)? {
            let closing = position + 1 < bytes.count && bytes[position + 1] == Self.slash
            let start = position + (closing ? 2 : 1)
            guard start < bytes.count, HTMLReader.isLetter(bytes[start]) else { return nil }
            var end = start
            while end < bytes.count, !Self.isNameEnd(bytes[end]) { end += 1 }
            position = end
            return (String(decoding: bytes[start..<end].map(HTMLReader.lowercased), as: UTF8.self), closing)
        }

        /// The next attribute, or nil at the tag's `>` (left at `position`) or when the bytes end
        /// first (`position` is then the end).
        mutating func attribute() -> Attribute? {
            let count = bytes.count
            while position < count, HTMLReader.isSpace(bytes[position]) || bytes[position] == Self.slash { position += 1 }
            guard position < count, bytes[position] != Self.greaterThan else { return nil }
            let nameStart = position
            // The first byte is the name's whatever it is, `=` included.
            position += 1
            let name: Range<Int>
            while true {
                guard position < count else { return nil }
                let byte = bytes[position]
                if byte == Self.equals {
                    name = nameStart..<position
                    position += 1
                    break
                }
                if HTMLReader.isSpace(byte) {
                    name = nameStart..<position
                    while position < count, HTMLReader.isSpace(bytes[position]) { position += 1 }
                    guard position < count else { return nil }
                    guard bytes[position] == Self.equals else {
                        return Attribute(name: name, value: position..<position, unquoted: false)
                    }
                    position += 1
                    break
                }
                if byte == Self.slash || byte == Self.greaterThan {
                    return Attribute(name: nameStart..<position, value: position..<position, unquoted: false)
                }
                position += 1
            }
            while position < count, HTMLReader.isSpace(bytes[position]) { position += 1 }
            guard position < count else { return nil }
            let first = bytes[position]
            if first == UInt8(ascii: "\"") || first == UInt8(ascii: "'") {
                let start = position + 1
                guard let close = bytes[start...].firstIndex(of: first) else {
                    position = count
                    return nil
                }
                position = close + 1
                return Attribute(name: name, value: start..<close, unquoted: false)
            }
            if first == Self.greaterThan { return Attribute(name: name, value: position..<position, unquoted: false) }
            let start = position
            while position < count, !HTMLReader.isSpace(bytes[position]), bytes[position] != Self.greaterThan { position += 1 }
            return position < count ? Attribute(name: name, value: start..<position, unquoted: true) : nil
        }

        /// Whether the element `name` ends at `index`: `</name` followed by a name end or the end
        /// of the bytes, in any ASCII case.
        func endTag(_ name: String, at index: Int) -> Bool {
            let pattern = Array(("</" + name).utf8)
            guard bytes[index] == Self.lessThan, index + pattern.count <= bytes.count,
                  zip(bytes[index...], pattern).allSatisfy({ HTMLReader.lowercased($0) == $1 }) else { return false }
            let after = index + pattern.count
            return after == bytes.count || Self.isNameEnd(bytes[after])
        }
    }

    /// HTML's "prescan a byte stream to determine its encoding", over bytes, so no encoding is
    /// assumed: comments (`<!-- … -->`) and the contents of raw text elements (scripts, styles,
    /// `<title>`, `<textarea>`, `<noscript>`, …) are skipped, other tags are read attribute by
    /// attribute (see `TagScanner`), and only a real `<meta>` tag declares: by `charset`, or by
    /// `http-equiv="content-type"` with a `content` that names a charset. A `<meta>` whose charset
    /// is unknown is passed over for the next one.
    struct CharsetPrescan {
        /// Elements whose contents is text: a `<meta>` in one is not a tag.
        static let rawText: Set<String> = [
            "script", "style", "textarea", "title", "noscript", "xmp", "iframe", "noembed", "noframes",
        ]

        private var scanner: TagScanner
        private var bytes: [UInt8] { scanner.bytes }
        private var position: Int {
            get { scanner.position }
            set { scanner.position = newValue }
        }

        init(bytes: [UInt8]) {
            scanner = TagScanner(bytes: bytes, position: 0)
        }

        private static let greaterThan = TagScanner.greaterThan
        private static let equals = TagScanner.equals

        mutating func encoding() -> String.Encoding? {
            let count = bytes.count
            while position < count {
                if starts("<!--", at: position) {
                    // The dashes of `<!--` may close it too: `<!-->` is a whole comment.
                    guard let end = find("-->", from: position + 2) else { return nil }
                    position = end + 3
                } else if bytes[position] == TagScanner.lessThan, case let (name, closing)? = scanner.tagName() {
                    if !closing, name == "meta" {
                        if let encoding = meta() { return encoding }
                        position += 1
                        continue
                    }
                    // A start or end tag: its attributes are read past, so a `>` in a quoted value
                    // does not end it.
                    while scanner.attribute() != nil {}
                    position += 1
                    if !closing, Self.rawText.contains(name), !skipRawText(name) { return nil }
                } else if starts("<!", at: position) || starts("</", at: position) || starts("<?", at: position) {
                    guard let end = bytes[position...].firstIndex(of: Self.greaterThan) else { return nil }
                    position = end + 1
                } else {
                    position += 1
                }
            }
            return nil
        }

        /// The attributes of a `<meta>` tag (`position` is past `<meta`) and the encoding they
        /// declare, if any. `position` is left at the tag's `>` (or the end).
        private mutating func meta() -> String.Encoding? {
            var seen = Set<String>()
            var gotPragma = false
            var needPragma: Bool?
            // Set by `charset` even when it names no encoding, so a later `content` is then ignored.
            var charset: String?
            while case let (name, value)? = attribute() {
                guard seen.insert(name).inserted else { continue }
                switch name {
                case "http-equiv":
                    if value == Array("content-type".utf8) { gotPragma = true }
                case "content":
                    if charset == nil, let declared = Self.charset(inContent: value) {
                        charset = declared
                        needPragma = true
                    }
                case "charset":
                    charset = String(decoding: value, as: UTF8.self)
                    needPragma = false
                default: break
                }
            }
            guard let needPragma, let charset, !needPragma || gotPragma else { return nil }
            return HTMLReader.encoding(named: charset)
        }

        /// The next attribute's name and value (see `TagScanner.attribute`), both lowercased.
        private mutating func attribute() -> (String, [UInt8])? {
            guard let attribute = scanner.attribute() else { return nil }
            return (String(decoding: bytes[attribute.name].map(HTMLReader.lowercased), as: UTF8.self),
                    bytes[attribute.value].map(HTMLReader.lowercased))
        }

        /// HTML's "extract a character encoding from a meta element": the name after `charset=`
        /// in a (lowercased) `content` value, quoted or up to a space or `;`.
        static func charset(inContent value: [UInt8]) -> String? {
            let keyword = Array("charset".utf8)
            var position = 0
            while true {
                guard let found = firstIndex(of: keyword, in: value, from: position) else { return nil }
                position = found + keyword.count
                while position < value.count, HTMLReader.isSpace(value[position]) { position += 1 }
                guard position < value.count, value[position] == equals else { continue }
                position += 1
                while position < value.count, HTMLReader.isSpace(value[position]) { position += 1 }
                guard position < value.count else { return nil }
                let first = value[position]
                if first == UInt8(ascii: "\"") || first == UInt8(ascii: "'") {
                    guard let close = value[(position + 1)...].firstIndex(of: first) else { return nil }
                    return String(decoding: value[(position + 1)..<close], as: UTF8.self)
                }
                let end = value[position...].firstIndex { HTMLReader.isSpace($0) || $0 == UInt8(ascii: ";") } ?? value.count
                return String(decoding: value[position..<end], as: UTF8.self)
            }
        }

        /// Moves `position` to the `</name` that ends a raw text element; false when the bytes end first.
        private mutating func skipRawText(_ name: String) -> Bool {
            while position < bytes.count {
                if scanner.endTag(name, at: position) { return true }
                position += 1
            }
            return false
        }

        /// Whether `text` (lowercase ASCII) is at `index`, in any ASCII case.
        private func starts(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard index + pattern.count <= bytes.count else { return false }
            return zip(bytes[index...], pattern).allSatisfy { HTMLReader.lowercased($0) == $1 }
        }

        private func find(_ text: String, from index: Int) -> Int? {
            Self.firstIndex(of: Array(text.utf8), in: bytes, from: index)
        }

        private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from index: Int) -> Int? {
            guard !pattern.isEmpty, bytes.count >= pattern.count, index <= bytes.count - pattern.count else { return nil }
            return (index...(bytes.count - pattern.count)).first { start in
                bytes[start..<(start + pattern.count)].elementsEqual(pattern)
            }
        }
    }

    /// The encoding an IANA charset name ("utf-8", "ISO-8859-1", "shift_jis") stands for in HTML.
    static func encoding(named name: String) -> String.Encoding? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoding = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        switch String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)) {
        case .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian: return .utf8
        case .isoLatin1, .ascii: return .windowsCP1252
        case let other: return other
        }
    }

    // MARK: Elements the parser does not know

    /// A new name for the attribute that carries an element's own name after `prepared` renamed
    /// it: `data-holos-<32 random hex digits>-tag`, made for each page read. A page cannot name it
    /// in advance, so an attribute the page itself has (`<p data-holos-tag="script">`) is never
    /// taken for one `prepared` added.
    static func originalNameAttribute() -> String {
        "data-holos-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "-tag"
    }

    /// Elements the tidying parser keeps (HTML 4 and its legacy extensions). It drops the tags of
    /// any other element, HTML5's included, and keeps their contents as if the tags were not there.
    static let knownToParser: Set<String> = [
        "a", "abbr", "acronym", "address", "applet", "area", "b", "base", "basefont", "bdo", "big",
        "blockquote", "body", "br", "button", "caption", "center", "cite", "code", "col", "colgroup",
        "dd", "del", "dfn", "dir", "div", "dl", "dt", "em", "fieldset", "font", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "html", "i", "iframe", "img",
        "input", "ins", "isindex", "kbd", "label", "legend", "li", "link", "map", "menu", "meta",
        "noframes", "noscript", "object", "ol", "optgroup", "option", "p", "param", "pre", "q", "s",
        "samp", "script", "select", "small", "span", "strike", "strong", "style", "sub", "sup",
        "table", "tbody", "td", "textarea", "tfoot", "th", "thead", "title", "tr", "tt", "u", "ul",
        "var", "embed", "nobr", "wbr", "marquee", "blink", "xmp", "listing", "plaintext", "layer",
        "ilayer", "spacer", "bgsound", "keygen", "rb", "rbc", "rp", "rt", "rtc", "ruby", "multicol",
        "nolayer",
    ]
    /// Unknown elements that stand as blocks become `div`s; every other one becomes a `span`.
    static let blockReplaced: Set<String> = [
        "article", "aside", "details", "dialog", "figcaption", "figure", "footer", "header", "hgroup",
        "main", "nav", "search", "section", "summary", "template",
    ]
    /// Elements none of whose contents is read. Every element inside one becomes a `span` (raw
    /// text elements aside), so the parser keeps the contents in place: it moves a template's
    /// table cells into the table around the template otherwise.
    static let opaque: Set<String> = ["template", "svg", "math"]
    /// Elements that are foreign content (SVG, MathML), where `/>` ends an element.
    static let foreign: Set<String> = ["svg", "math"]
    /// HTML's void elements: never any contents, and the only HTML elements `/>` ends.
    static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    /// Elements whose contents is text, never tags.
    static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]

    /// `html` with every element the tidying parser does not know renamed to one it does, its own
    /// name kept in `nameAttribute` (see `originalNameAttribute`): `<nav class="x">` becomes
    /// `<div data-holos-…-tag="nav" class="x">`. The parser then keeps it as an element with all its
    /// contents, nested ones included, for `Walker` to read or skip. Only tag names change, a
    /// self-closing slash HTML ignores is dropped (see `void`), and `<` in raw text elements other
    /// than scripts and styles (which the parser reads as text) is escaped; comments are copied
    /// as they are.
    static func prepared(_ html: String, nameAttribute: String) -> String {
        let bytes = Array(html.utf8)
        let count = bytes.count
        var output: [UInt8] = []
        output.reserveCapacity(count + count / 16)
        // Open opaque elements, innermost last.
        var opaqueOpen: [String] = []
        var index = 0

        func starts(_ text: String, at position: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard position + pattern.count <= count else { return false }
            return zip(bytes[position...], pattern).allSatisfy { lowercased($0) == $1 }
        }
        func replacement(_ name: String) -> String { blockReplaced.contains(name) ? "div" : "span" }

        while index < count {
            guard bytes[index] == UInt8(ascii: "<") else {
                output.append(bytes[index])
                index += 1
                continue
            }
            if starts("<!--", at: index) {
                var end = index + 4
                while end < count, bytes[end] != UInt8(ascii: "-") || !starts("-->", at: end) { end += 1 }
                end = min(count, end + 3)
                output += bytes[index..<end]
                index = end
                continue
            }
            var scanner = TagScanner(bytes: bytes, position: index)
            guard let (name, closing) = scanner.tagName() else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let tagStart = index
            let cursor = scanner.position
            // The tag ends at the first `>` outside a quoted attribute value (see `TagScanner`).
            var last: TagScanner.Attribute?
            while let attribute = scanner.attribute() { last = attribute }
            let end = scanner.position
            guard end < count else {
                // An unfinished tag: the rest is copied for the parser to make of it what it can.
                output += bytes[tagStart...]
                break
            }
            // `/>` outside an unquoted value (in `href=a/>` the slash is the value's).
            let slashInValue = last.map { $0.unquoted && $0.value.upperBound == end } ?? false
            let slash = !closing && !slashInValue && bytes[end - 1] == UInt8(ascii: "/")
            // As HTML reads it, the slash makes an empty element only of a void element or in
            // foreign content (SVG, MathML, `<svg/>` itself); `<template/>` and `<nav/>` stay open
            // up to their end tags. The parser would take every `/>` as empty, so an ignored slash
            // is dropped. A void element is empty with or without it.
            let insideForeign = opaqueOpen.contains { foreign.contains($0) }
            let selfClosing = slash && (void.contains(name) || foreign.contains(name) || insideForeign)
            let empty = selfClosing || (void.contains(name) && !insideForeign)
            let attributes = slash && !selfClosing ? bytes[cursor..<(end - 1)] : bytes[cursor..<end]
            index = end + 1

            if closing {
                let renamed: String?
                if let innermost = opaqueOpen.last {
                    if name == innermost {
                        opaqueOpen.removeLast()
                        renamed = opaqueOpen.isEmpty ? replacement(name) : "span"
                    } else {
                        renamed = rawText.contains(name) && name != "title" ? nil : "span"
                    }
                } else {
                    renamed = knownToParser.contains(name) ? nil : replacement(name)
                }
                if let renamed { output += Array("</\(renamed)>".utf8) } else { output += bytes[tagStart..<index] }
                continue
            }

            let insideOpaque = !opaqueOpen.isEmpty
            // In an opaque element a raw text element keeps its name, so the parser still reads
            // its contents as text; `<title>` there is an SVG title, which is markup.
            let isRawText = rawText.contains(name) && !(insideOpaque && name == "title") && !selfClosing
            let renamed: String?
            if insideOpaque {
                renamed = isRawText ? nil : "span"
            } else {
                renamed = knownToParser.contains(name) ? nil : replacement(name)
            }
            if opaque.contains(name), !selfClosing { opaqueOpen.append(name) }
            if let renamed {
                var tag = "<" + renamed
                if !insideOpaque, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }) {
                    tag += " \(nameAttribute)=\"\(name)\""
                }
                output += Array(tag.utf8)
                output += selfClosing ? attributes.dropLast() : attributes
                // `<path/>` and `<source>` become explicitly empty elements: `<span/>` could be
                // taken for an open one, hiding the text after it.
                output += Array((empty ? "></\(renamed)>" : ">").utf8)
            } else {
                // As written, less an ignored slash.
                output += bytes[tagStart..<cursor]
                output += attributes
                output.append(UInt8(ascii: ">"))
            }
            if isRawText {
                // Copied as it is up to its end tag, which the loop then reads.
                var close = index
                while close < count, !scanner.endTag(name, at: close) { close += 1 }
                if name == "script" || name == "style" {
                    output += bytes[index..<close]
                } else {
                    // The parser reads tags in the others (`<textarea><nav>…`), so their `<` is
                    // escaped: all it can do there is start a tag.
                    for byte in bytes[index..<close] {
                        if byte == UInt8(ascii: "<") { output += Array("&lt;".utf8) } else { output.append(byte) }
                    }
                }
                index = close
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercased(byte))
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
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

    struct Walker {
        /// An `<ol>` being read: the next item's number and how items are numbered.
        struct OrderedList {
            var next: Int
            var step: Int
            var type: String
        }

        /// The attribute `prepared` put an element's own name in, this page's own.
        let nameAttribute: String
        var builder = ReadableDocument.Builder()
        var inline = ""
        var row: [String]?
        /// Open lists, innermost last; nil for an unordered one.
        var lists: [OrderedList?] = []
        /// "3. " before the first text of an ordered list item.
        var marker: String?
        /// The paragraphs of the table cell being read, which make up its text; nil outside cells.
        var cell: [String]?

        mutating func flush() {
            emit(collapse(inline))
            inline = ""
        }

        /// Writes a block of text, the pending list marker ("3. ") before it: a paragraph, the
        /// next of a table cell's paragraphs, or, with `heading`, a section heading outside cells
        /// (so "<ol><li><h2>Install</h2></li></ol>" gives the section, and its chapter, "1. Install").
        /// Every block the walker writes goes through here, so no block drops an item's number.
        mutating func emit(_ text: String, heading level: Int? = nil) {
            guard !text.isEmpty else { return }
            if cell != nil {
                cell?.append((marker ?? "") + text)
            } else if let level {
                builder.heading((marker ?? "") + text, level: level)
            } else {
                builder.paragraph((marker ?? "") + text)
            }
            marker = nil
        }

        mutating func walk(_ node: XMLNode) {
            if node.kind == .text {
                inline += node.stringValue ?? ""
                return
            }
            guard node.kind == .element else { return }
            if isSkipped(node) { return }
            let name = self.name(of: node)
            // A heading in a table cell is part of the cell's text, read as a block. Elsewhere it
            // starts a section, an ordered item's number before it.
            let heading = name.count == 2 && name.first == "h" ? Int(String(name.last!)).flatMap { (1...6).contains($0) ? $0 : nil } : nil
            if let level = heading, cell == nil {
                flush()
                emit(collapse(text(of: node)), heading: level)
                return
            }
            // A cell is read like the rest of the page (lists keep their numbers, blocks stay
            // apart, a nested table's rows are read), its paragraphs joined into one line. The
            // cell stands on its own: a list around its table does not number its items, and an
            // item's number stays for the row.
            if name == "td" || name == "th" {
                flush()
                let outer = (cell, lists, marker)
                cell = []
                lists = []
                marker = nil
                for child in node.children ?? [] { walk(child) }
                flush()
                let text = cell?.joined(separator: " ") ?? ""
                (cell, lists, marker) = outer
                if !text.isEmpty {
                    if row != nil { row?.append(text) } else { emit(text) }
                }
                return
            }
            if name == "tr" {
                flush()
                let outer = row
                row = []
                for child in node.children ?? [] { walk(child) }
                flush()
                let cells = row ?? []
                row = outer
                if !cells.isEmpty { emit(cells.joined(separator: "; ")) }
                return
            }
            // Ordered list items keep their numbers, as the page shows them: `start`, `reversed`,
            // `type` (1, a, A, i, I), and an item's `value` are honored. Bullets are not read.
            // A list nested in an ordered item before the item's own text leaves the item's number
            // for that text: "<li><ul><li>substep</li></ul>main step</li>" reads "1. main step".
            if name == "ol" || name == "ul" || name == "menu" {
                flush()
                let pending = marker
                marker = nil
                lists.append(name == "ol" ? Self.orderedList(node) : nil)
                for child in node.children ?? [] { walk(child) }
                flush()
                lists.removeLast()
                marker = pending
                return
            }
            if name == "li", let open = lists.last {
                flush()
                if var list = open {
                    if let value = Self.counter(Self.attribute("value", of: node)) { list.next = value }
                    marker = Self.marker(list.next, type: list.type) + " "
                    // Never traps: a counter at the integer bounds stays there.
                    let (advanced, overflow) = list.next.addingReportingOverflow(list.step)
                    if !overflow { list.next = advanced }
                    lists[lists.count - 1] = list
                }
                for child in node.children ?? [] { walk(child) }
                flush()
                marker = nil
                return
            }
            let isBlock = HTMLReader.blocks.contains(name) || heading != nil
            if isBlock { flush() }
            for child in node.children ?? [] { walk(child) }
            if isBlock { flush() }
        }

        /// An element's HTML name, lowercased: the one it had before `prepared` renamed it, else
        /// its own.
        func name(of node: XMLNode) -> String {
            Self.attribute(nameAttribute, of: node)?.lowercased()
                ?? (node.localName ?? node.name ?? "").lowercased()
        }

        /// A skipped element (a script, a navigation bar), or one the page hides: with a `hidden`
        /// attribute, `aria-hidden="true"`, an inline `display: none`, or a `<dialog>` that is not
        /// open. Nothing inside it is read.
        func isSkipped(_ node: XMLNode) -> Bool {
            let name = self.name(of: node)
            if HTMLReader.skipped.contains(name) { return true }
            if name == "dialog", Self.attribute("open", of: node) == nil { return true }
            if Self.attribute("hidden", of: node) != nil { return true }
            if Self.attribute("aria-hidden", of: node)?.lowercased() == "true" { return true }
            return Self.attribute("style", of: node).map(Self.hidesElement) ?? false
        }

        /// Whether an inline style sets `display: none` (in any case, `!important` or not).
        static func hidesElement(_ style: String) -> Bool {
            style.split(separator: ";").contains { declaration in
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "display" else { return false }
                var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.hasSuffix("!important") {
                    value = value.dropLast("!important".count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value == "none"
            }
        }

        /// The attribute whose local name is `name` in any ASCII case (HTML attribute names are
        /// case-insensitive); with `qualified`, only one whose whole name is that, so `lang` is
        /// told apart from `xml:lang`.
        static func attribute(_ name: String, of node: XMLNode, qualified: String? = nil) -> String? {
            (node as? XMLElement)?.attributes?.first {
                if let qualified { return $0.name?.lowercased() == qualified }
                return ($0.localName ?? $0.name)?.lowercased() == name
            }?.stringValue?.trimmingCharacters(in: .whitespaces)
        }

        static func orderedList(_ node: XMLNode) -> OrderedList {
            let reversed = attribute("reversed", of: node) != nil
            let items = (node.children ?? []).filter { ($0.localName ?? $0.name)?.lowercased() == "li" }.count
            let start = counter(attribute("start", of: node)) ?? (reversed ? items : 1)
            let type = attribute("type", of: node) ?? "1"
            return OrderedList(next: start, step: reversed ? -1 : 1, type: type)
        }

        /// The largest list number `start` or `value` may set, either sign.
        static let counterLimit = 1_000_000_000

        /// A `start` or `value` attribute as a list number; nil (so the default numbering
        /// applies) when it is not an integer or is beyond `counterLimit`.
        static func counter(_ text: String?) -> Int? {
            guard let text, let value = Int(text), (-counterLimit...counterLimit).contains(value) else { return nil }
            return value
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
        func text(of node: XMLNode) -> String {
            if node.kind == .text { return node.stringValue ?? "" }
            guard node.kind == .element, !isSkipped(node) else { return "" }
            let separator = HTMLReader.blocks.contains(name(of: node)) ? " " : ""
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

    /// The title is the metadata title, else a title-like first paragraph; a first paragraph that
    /// says the title is its level-1 heading, read once. Headings `reflow` set apart become
    /// level-2 sections, so chapters (see `isHeading`).
    static func document(paragraphs: [String], declaredTitle: String?, author: String?) -> ReadableDocument {
        var title = declaredTitle.flatMap { $0.isEmpty ? nil : $0 }
        var builder = ReadableDocument.Builder()
        var start = 0
        if paragraphs.count > 1, PlainTextReader.looksLikeTitle(paragraphs[0]),
           title.map({ ReadableDocument.sameTitle($0, paragraphs[0]) }) ?? true {
            title = title ?? paragraphs[0]
            builder.heading(paragraphs[0], level: 1)
            start = 1
        }
        let candidates = paragraphs.map(isHeadingCandidate)
        var index = start
        while index < paragraphs.count {
            // A run of one or two heading-like paragraphs ("Chapter 2", "Methods") after the start,
            // the title, or a finished sentence, with body text after it, is headings.
            var end = index
            while end < paragraphs.count, candidates[end] { end += 1 }
            let run = index..<end
            let afterBreak = index == start || endsSentence(paragraphs[index - 1])
            if !run.isEmpty, run.count <= 2, afterBreak, end < paragraphs.count {
                for heading in run { builder.heading(paragraphs[heading], level: 2) }
            } else {
                for paragraph in run { builder.paragraph(paragraphs[paragraph]) }
            }
            if end < paragraphs.count { builder.paragraph(paragraphs[end]) }
            index = end + 1
        }
        return ReadableDocument(title: title, author: author, sections: builder.sections)
    }

    /// Short (80 characters at most), one line, with a letter, not ending like a sentence or a
    /// clause, and not a bulleted or lettered list item: what `reflow` sets apart as a heading.
    /// A numbered heading ("2. Methods", "3.1 Results") qualifies; a long numbered list does not,
    /// because a heading run is at most two paragraphs.
    static func isHeadingCandidate(_ paragraph: String) -> Bool {
        paragraph.count <= 80 && PlainTextReader.looksLikeTitle(paragraph) && paragraph.contains(where: \.isLetter)
            && paragraph.range(of: #"^\s*([-–—•*·▪◦]|\(?[0-9]{1,3}\)|\(?[a-zA-Z][.)])\s"#,
                               options: .regularExpression) == nil
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
        let lines = DocumentText.withLFLineEndings(page).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
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
