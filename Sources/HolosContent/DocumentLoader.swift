import AppKit
import Foundation
import HolosCore
import PDFKit

/// Reads local files into a `ReadableDocument` with built-in macOS APIs only.
public enum DocumentLoader {
    public static let supportedExtensions = [
        "txt", "text", "md", "markdown", "html", "htm", "pdf", "rtf", "rtfd", "docx", "doc", "odt",
    ]

    /// Unknown extensions are read as UTF-8 plain text. Callable from any thread: none of the readers is AppKit's
    /// HTML importer (the one that must run on the main thread), so the app loads files off the main actor. In a
    /// cancelled task a PDF stops between pages with `CancellationError`.
    public static func load(_ url: URL) throws -> ReadableDocument {
        // A FIFO or a device would block the read until a writer comes (a Stop could not end it): refused. A package
        // (an RTFD document) is a folder.
        var metadata = stat()
        if stat(RawFilePath.system(url), &metadata) == 0 {
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {
                throw HolosError.invalidInput("\(url.lastPathComponent) is not a document file.")
            }
        }
        let document: ReadableDocument
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            document = MarkdownReader.document(from: try utf8(url))
        case "html", "htm":
            document = HTMLReader.document(from: try contents(url))
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

    /// The bytes of the file at `url`, opened without waiting and checked on the descriptor (see `openRegularFile`):
    /// a FIFO put in its place after the check above is refused rather than waited on.
    private static func contents(_ url: URL) throws -> Data {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    private static func utf8(_ url: URL) throws -> String {
        guard let text = DocumentText.decode(try contents(url)) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not UTF-8 text.")
        }
        return text
    }
}

/// Bytes of a text file (or stdin) as a string: UTF-8, or UTF-16 or UTF-32 when a byte order
/// mark says so (Windows Notepad saves "Unicode" as UTF-16 with one). A byte order mark decides
/// the encoding: malformed sequences after one become U+FFFD, never a reason to read the bytes
/// in another encoding (see `decodeMarked`). Without a mark, nil for anything but valid UTF-8.
/// One leading byte order mark is dropped, so it never hides YAML front matter or ends up in a
/// title, and every line ends in LF (see `withLFLineEndings`).
public enum DocumentText {
    public static func decode(_ data: Data) -> String? {
        let text = decodeMarked(data) ?? decode(data, as: .utf8)
        return text.map(withLFLineEndings)
    }

    /// When `data` starts with a byte order mark: the rest in the encoding it names, each malformed
    /// sequence (an invalid UTF-8 byte, a lone surrogate, a trailing partial code unit) replaced
    /// with U+FFFD. The mark itself is dropped. Nil without a mark.
    static func decodeMarked(_ data: Data) -> String? {
        guard let (length, encoding) = byteOrderMark(data) else { return nil }
        let bytes = [UInt8](data.dropFirst(length))
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian:
            return repaired(bytes, width: 2, bigEndian: encoding == .utf16BigEndian, as: UTF16.self)
        case .utf32LittleEndian, .utf32BigEndian:
            return repaired(bytes, width: 4, bigEndian: encoding == .utf32BigEndian, as: UTF32.self)
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// `bytes` as code units of `width` bytes in the given byte order, decoded with `codec`,
    /// malformed sequences replaced with U+FFFD; leftover bytes that make no whole unit are one
    /// more U+FFFD.
    private static func repaired<Codec: Unicode.Encoding>(
        _ bytes: [UInt8], width: Int, bigEndian: Bool, as codec: Codec.Type
    ) -> String where Codec.CodeUnit: FixedWidthInteger {
        let whole = bytes.count / width * width
        let units = stride(from: 0, to: whole, by: width).map { start in
            bytes[start..<(start + width)].enumerated().reduce(Codec.CodeUnit(0)) { unit, pair in
                let shift = (bigEndian ? width - 1 - pair.offset : pair.offset) * 8
                return unit | (Codec.CodeUnit(pair.element) << shift)
            }
        }
        return String(decoding: units, as: codec) + (whole < bytes.count ? "\u{FFFD}" : "")
    }

    /// `data` as text, refusing anything malformed: UTF-8 (a leading UTF-8 byte order mark dropped), or UTF-16 or
    /// UTF-32 after their byte order mark, each decoded strictly (an invalid byte, a truncated code unit, an unpaired
    /// surrogate, or a value that is no Unicode scalar gives nil). Line endings become LF. Unlike `decode`, which
    /// repairs a marked file with U+FFFD, for text that must be read exactly as written (`voiceislocal say
    /// --text-file`).
    public static func decodeStrictly(_ data: Data) -> String? {
        guard let (length, encoding) = byteOrderMark(data), encoding != .utf8 else {
            let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            return String(validating: body, as: UTF8.self).map(withLFLineEndings)
        }
        let bytes = [UInt8](data.dropFirst(length))
        let text: String?
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian:
            text = strict(bytes, width: 2, bigEndian: encoding == .utf16BigEndian, as: UTF16.self)
        default:
            text = strict(bytes, width: 4, bigEndian: encoding == .utf32BigEndian, as: UTF32.self)
        }
        return text.map(withLFLineEndings)
    }

    /// `bytes` as code units of `width` bytes in the given byte order, decoded with `codec`; nil for a leftover byte or
    /// any malformed sequence.
    private static func strict<Codec: Unicode.Encoding>(
        _ bytes: [UInt8], width: Int, bigEndian: Bool, as codec: Codec.Type
    ) -> String? where Codec.CodeUnit: FixedWidthInteger {
        guard bytes.count % width == 0 else { return nil }
        let units = stride(from: 0, to: bytes.count, by: width).map { start in
            bytes[start..<(start + width)].enumerated().reduce(Codec.CodeUnit(0)) { unit, pair in
                let shift = (bigEndian ? width - 1 - pair.offset : pair.offset) * 8
                return unit | (Codec.CodeUnit(pair.element) << shift)
            }
        }
        return String(validating: units, as: codec)
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

    // MARK: Encoding

    /// A page's bytes as text, the encoding picked as a browser picks it:
    /// 1. a byte order mark: UTF-8, UTF-16, or UTF-32, malformed sequences read as U+FFFD (the
    ///    mark decides; see `DocumentText.decodeMarked`);
    /// 2. else the charset declared in the first 1024 bytes, by `<meta charset>` or
    ///    `<meta http-equiv="Content-Type" content="…; charset=…">` (any ASCII case), outside
    ///    comments and scripts (see `CharsetPrescan`). As in
    ///    browsers, ISO-8859-1 and ASCII mean Windows-1252, and UTF-16 or UTF-32 without a mark
    ///    means UTF-8;
    /// 3. else UTF-8 when the bytes are valid UTF-8;
    /// 4. else Windows-1252, HTML's default.
    /// Once 1 or 2 decides the encoding, the page is read in it and nothing else: each malformed
    /// or truncated sequence becomes U+FFFD (see `lossy`), never a reason to try another encoding.
    /// Only a page with neither a mark nor a supported declaration gets the 3-then-4 probe. One
    /// leading U+FEFF is dropped, and line endings are made LF (see `DocumentText.normalized`).
    static func decode(_ data: Data) -> String {
        DocumentText.normalized(decodeKeepingMark(data))
    }

    private static func decodeKeepingMark(_ data: Data) -> String {
        if let text = DocumentText.decodeMarked(data) { return text }
        if let declared = declaredEncoding(data), let text = lossy(data, as: declared) { return text }
        return DocumentText.decode(data, as: .utf8) ?? windows1252(data)
    }

    /// `data` in `encoding`, each malformed or truncated sequence replaced with U+FFFD and the
    /// rest kept. Nil only when Foundation cannot decode `encoding` at all, which makes the
    /// declaration unsupported (as an unknown charset name is).
    static func lossy(_ data: Data, as encoding: String.Encoding) -> String? {
        switch encoding {
        case .utf8: return String(decoding: data, as: UTF8.self)
        case .windowsCP1252: return windows1252(data)
        default:
            if let text = String(data: data, encoding: encoding) { return text }
            // Foundation's detector, limited to the one encoding, decodes lossily: a malformed
            // sequence becomes U+FFFD and decoding resumes at the next byte that can start one.
            var converted: NSString?
            var usedLossy: ObjCBool = false
            let used = NSString.stringEncoding(
                for: data,
                encodingOptions: [.suggestedEncodingsKey: [encoding.rawValue], .useOnlySuggestedEncodingsKey: true,
                                  .allowLossyKey: true],
                convertedString: &converted, usedLossyConversion: &usedLossy)
            guard used == encoding.rawValue, let converted else { return nil }
            return converted as String
        }
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
    /// is unknown is passed over for the next one. `<plaintext>` ends the scan: all after it is text.
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
                    guard let end = HTMLReader.commentEnd(in: bytes, from: position) else { return nil }
                    position = end
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
                    // `<plaintext>` has no end tag: everything after it is text.
                    if !closing, name == "plaintext" { return nil }
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
    /// as they are, an abruptly closed one written out in full (see `commentEnd`).
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
                guard let end = commentEnd(in: bytes, from: index) else {
                    // An unfinished comment: the rest is copied for the parser to make of it what it can.
                    output += bytes[index...]
                    break
                }
                // Written out in full, so the parser reads the comment where the prescan does: an
                // abruptly closed `<!-->` or `<!--->` becomes `<!---->`, and one closed with
                // `--!>` ends with `-->`.
                let text = commentText(in: bytes, from: index, to: end)
                output += Array("<!--".utf8) + text + Array("-->".utf8)
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
            if name == "plaintext", !insideForeign {
                // `<plaintext>` has no end tag: all after it is its text, `</plaintext>` included,
                // so the rest is escaped into it (and it is not read, see `skipped`). In an opaque
                // element it is a `span` like every other element there, all of it unread.
                let element = insideOpaque ? "span" : "plaintext"
                output += Array("<\(element)>".utf8)
                for byte in bytes[index...] {
                    if byte == UInt8(ascii: "<") { output += Array("&lt;".utf8) } else { output.append(byte) }
                }
                output += Array("</\(element)>".utf8)
                break
            }
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

    /// Where the comment whose `<!--` is at `start` ends: just past its `-->` or `--!>`, or nil
    /// when it never ends. As HTML reads it, the dashes of `<!--` may close it too: `<!-->` and
    /// `<!--->` are whole, empty comments; `--!>` ends one only after `<!--` (`<!--!>` does not).
    /// The charset prescan (`CharsetPrescan`) and `prepared` both read comments by this rule, so
    /// neither takes text the other reads as a comment.
    static func commentEnd(in bytes: [UInt8], from start: Int) -> Int? {
        let dash = UInt8(ascii: "-"), bang = UInt8(ascii: "!"), greaterThan = UInt8(ascii: ">")
        var index = start + 2
        while index + 2 < bytes.count {
            if bytes[index] == dash, bytes[index + 1] == dash {
                if bytes[index + 2] == greaterThan { return index + 3 }
                if index >= start + 4, index + 3 < bytes.count, bytes[index + 2] == bang,
                   bytes[index + 3] == greaterThan { return index + 4 }
            }
            index += 1
        }
        return nil
    }

    /// The text of the comment from `start` (its `<!--`) to `end` (see `commentEnd`), without
    /// its `-->` or `--!>`; empty for `<!-->` and `<!--->`.
    static func commentText(in bytes: [UInt8], from start: Int, to end: Int) -> ArraySlice<UInt8> {
        let closing = end - start >= 8 && bytes[end - 2] == UInt8(ascii: "!") ? 4 : 3
        return start + 4 <= end - closing ? bytes[(start + 4)..<(end - closing)] : []
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
            // A closed disclosure (`details` without `open`) shows only its summary, its first
            // `summary` child; the rest is read only when it is open.
            if name == "details", Self.attribute("open", of: node) == nil {
                flush()
                if let summary = (node.children ?? []).first(where: { $0.kind == .element && self.name(of: $0) == "summary" }) {
                    walk(summary)
                }
                flush()
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

        /// Whether an inline style's effective `display` is `none`: the declaration that wins the
        /// cascade within the attribute, so `display:none; display:block` shows the element and
        /// `display:none !important; display:block` hides it. A value with `var()` is accepted,
        /// as a browser accepts it, and counts once its variables are substituted from the
        /// attribute's own custom properties (`--mode:none; display:var(--mode)` hides). One that
        /// is invalid once substituted makes `display` its initial `inline`, which shows the
        /// element, and so does one this attribute cannot resolve: the text is read rather than
        /// possibly visible text dropped.
        static func hidesElement(_ style: String) -> Bool {
            let style = InlineStyle(style)
            guard var display = style.value(of: "display", isValid: {
                InlineStyle.isDisplayValue($0) || InlineStyle.usesVariables($0)
            }) else { return false }
            if InlineStyle.usesVariables(display) {
                guard case .value(let substituted) = style.substitutingVariables(in: display) else { return false }
                display = substituted
            }
            return HTMLReader.collapse(display).lowercased() == "none"
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

    /// The declarations of an HTML `style` attribute, read the way a browser cascades them within
    /// the one attribute: per property (names in any case), an `!important` declaration beats a
    /// normal one, and among equals the last wins. Declarations with an empty or invalid value are
    /// dropped, as a browser drops them, so they never override an earlier valid one.
    struct InlineStyle {
        struct Declaration: Equatable {
            var property: String
            var value: String
            var important: Bool
        }

        let declarations: [Declaration]

        init(_ style: String) {
            declarations = Self.split(Self.strippingComments(style)).compactMap(Self.declaration)
        }

        /// The effective value of `property`, as written, among declarations whose value
        /// `isValid` accepts; nil when none sets it.
        func value(of property: String, isValid: (String) -> Bool = { _ in true }) -> String? {
            let property = Self.propertyName(property)
            var winner: Declaration?
            for declaration in declarations where declaration.property == property && isValid(declaration.value) {
                if let current = winner, current.important, !declaration.important { continue }
                winner = declaration
            }
            return winner?.value
        }

        /// A property name as CSS matches it: a custom property's (`--name`) by case, any
        /// other's in any ASCII case.
        static func propertyName(_ name: String) -> String {
            name.hasPrefix("--") ? name : name.lowercased()
        }

        /// Whether `value` uses a custom property (`var(`, in any case). A browser accepts such
        /// a declaration whatever the rest of it says, and gives the property its value once the
        /// variables are substituted (see `substitutingVariables`).
        static func usesVariables(_ value: String) -> Bool {
            value.range(of: "var(", options: .caseInsensitive) != nil
        }

        /// What substituting a value's `var()` references gives.
        enum Substitution: Equatable {
            /// The value with every reference replaced.
            case value(String)
            /// Invalid at computed-value time, as CSS makes it: a reference to a variable in a
            /// cycle, to one set to `initial`, or to one that is itself invalid, with no fallback.
            case invalid
            /// Cannot be told here: a reference to a variable this attribute does not set (an
            /// ancestor or a style sheet may set it), or references nested too deep.
            case unknown
        }

        /// `value` with each `var(--name[, fallback])` replaced by the value this attribute's own
        /// `--name` declaration gives, itself substituted, as CSS substitutes it: a variable that
        /// is invalid (set to `initial`, in a reference cycle, or with an invalid reference of its
        /// own) gives the reference's fallback, and without one makes the whole value invalid.
        /// Every variable in a cycle is invalid, whatever fallbacks its own references have.
        func substitutingVariables(in value: String) -> Substitution {
            substitute(value, resolving: []).outcome
        }

        /// `substitutingVariables` for a value inside the variables of `stack` (outermost first),
        /// with the variables of `stack` that references in it close a cycle through.
        private func substitute(_ value: String, resolving stack: [String]) -> (outcome: Substitution, cycles: Set<String>) {
            guard stack.count < 32 else { return (.unknown, []) }
            let characters = Array(value)
            var result = ""
            var cycles = Set<String>()
            var invalid = false
            var unknown = false
            var index = 0
            while index < characters.count {
                guard index + 4 <= characters.count,
                      String(characters[index..<(index + 4)]).lowercased() == "var(" else {
                    result.append(characters[index])
                    index += 1
                    continue
                }
                // The reference's arguments, to its matching ")", and the first top-level comma.
                // An unclosed reference ends with the value, as CSS closes it.
                var nesting = 1
                var close = index + 4
                var comma: Int?
                while close < characters.count {
                    let character = characters[close]
                    if character == "(" { nesting += 1 }
                    if character == ")" { nesting -= 1; if nesting == 0 { break } }
                    if character == ",", nesting == 1, comma == nil { comma = close }
                    close += 1
                }
                let name = String(characters[(index + 4)..<(comma ?? close)]).trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = comma.map { String(characters[($0 + 1)..<close]) }
                index = close + 1
                guard name.hasPrefix("--") else {
                    invalid = true
                    continue
                }
                // The variable's own value. Every reference is resolved, even once the value is
                // invalid, so each cycle through it is found.
                var variable: Substitution
                if stack.contains(name) {
                    // A reference back to a variable being resolved: every variable from it to
                    // here is in a cycle, and invalid, the one holding this reference included.
                    cycles.insert(name)
                    invalid = true
                    continue
                } else if let own = self.value(of: name) {
                    if own.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "initial" {
                        variable = .invalid
                    } else {
                        let (outcome, inner) = substitute(own, resolving: stack + [name])
                        let through = inner.subtracting([name])
                        if !through.isEmpty {
                            // A cycle through a variable further out holds this one and the value.
                            cycles.formUnion(through)
                            invalid = true
                            continue
                        }
                        variable = inner.contains(name) ? .invalid : outcome
                    }
                } else {
                    variable = .unknown
                }
                if variable == .invalid, let fallback {
                    let (outcome, inner) = substitute(fallback, resolving: stack)
                    cycles.formUnion(inner)
                    variable = inner.isEmpty ? outcome : .invalid
                }
                switch variable {
                case .value(let text): result += " " + text + " "
                case .invalid: invalid = true
                case .unknown: unknown = true
                }
            }
            return (invalid ? .invalid : unknown ? .unknown : .value(result), cycles)
        }

        /// A `display` value a browser accepts, by the property's grammar (CSS Display 3, with
        /// MathML Core's `math`):
        /// `[<display-outside> || <display-inside>] | <display-listitem> | <display-internal> |
        /// <display-box> | <display-legacy>`, or a CSS-wide keyword alone. Keywords of a
        /// multi-keyword value come in any order, each at most once; `none`, `contents`, the
        /// internal and legacy values, and the CSS-wide keywords stand alone. So "block flow"
        /// and "list-item block" are valid, and "none block" and "inline inline" are not.
        static func isDisplayValue(_ value: String) -> Bool {
            let words = value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard (1...3).contains(words.count), Set(words).count == words.count else { return false }
            if words.count == 1, displaySingles.contains(words[0]) { return true }
            let outside = words.filter(displayOutside.contains)
            let inside = words.filter(displayInside.contains)
            let listItem = words.filter { $0 == "list-item" }
            guard outside.count + inside.count + listItem.count == words.count, outside.count <= 1 else { return false }
            if listItem.isEmpty {
                // <display-outside> || <display-inside>: one of each at most (one alone is a single).
                return inside.count <= 1
            }
            // <display-listitem>: list-item with at most one outside and at most flow or flow-root.
            return inside.count <= 1 && inside.allSatisfy { $0 == "flow" || $0 == "flow-root" }
        }

        static let cssWide: Set<String> = ["inherit", "initial", "unset", "revert", "revert-layer"]

        static let displayOutside: Set<String> = ["block", "inline", "run-in"]

        static let displayInside: Set<String> = ["flow", "flow-root", "table", "flex", "grid", "ruby", "math"]

        /// Values valid only as the whole declaration: <display-box>, <display-internal>,
        /// <display-legacy> (with the prefixed forms every engine still accepts), and the
        /// CSS-wide keywords. The outside and inside keywords and `list-item` are valid alone too.
        static let displaySingles: Set<String> = cssWide.union(displayOutside).union(displayInside).union([
            "none", "contents", "list-item",
            "table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell",
            "table-column-group", "table-column", "table-caption", "ruby-base", "ruby-text",
            "ruby-base-container", "ruby-text-container",
            "inline-block", "inline-table", "inline-flex", "inline-grid",
            "-webkit-box", "-webkit-inline-box", "-webkit-flex", "-webkit-inline-flex",
        ])

        /// One `name: value [!important]` declaration, or nil when it has no name or no value.
        /// Names are lowercased, except a custom property's (`--name`), which CSS matches by
        /// case; values are kept as written (a `var()` in one names a custom property).
        static func declaration(_ text: String) -> Declaration? {
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let property = propertyName(unescaped(text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)))
            var value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            // `!important` as written: an escaped `!` is part of a name, not the flag.
            if let bang = value.lastIndex(of: "!"), bang == value.startIndex || value[value.index(before: bang)] != "\\",
               unescaped(value[value.index(after: bang)...].trimmingCharacters(in: .whitespacesAndNewlines))
                   .lowercased() == "important" {
                important = true
                value = value[..<bang].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            value = unescaped(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !property.isEmpty, !property.contains(where: \.isWhitespace), !value.isEmpty else { return nil }
            return Declaration(property: property, value: value, important: important)
        }

        /// `text` with its CSS escapes decoded, as the tokenizer reads them: a backslash and one
        /// to six hex digits is that code point (zero, a surrogate, or one past U+10FFFF is
        /// U+FFFD), one whitespace after the digits belongs to the escape, and a backslash before
        /// any other character is that character. A backslash before a line break, or at the end,
        /// is kept. So `\6e one` and `n\6f ne` are `none`.
        static func unescaped(_ text: String) -> String {
            guard text.contains("\\") else { return text }
            let scalars = Array(text.unicodeScalars)
            var result = String.UnicodeScalarView()
            var index = 0
            func isHex(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && scalar.properties.isASCIIHexDigit }
            while index < scalars.count {
                let scalar = scalars[index]
                guard scalar == "\\", index + 1 < scalars.count, !["\n", "\r", "\u{0C}"].contains(scalars[index + 1]) else {
                    result.append(scalar)
                    index += 1
                    continue
                }
                index += 1
                guard isHex(scalars[index]) else {
                    result.append(scalars[index])
                    index += 1
                    continue
                }
                var value: UInt32 = 0
                var digits = 0
                while index < scalars.count, digits < 6, isHex(scalars[index]) {
                    value = value * 16 + (UInt32(String(scalars[index]), radix: 16) ?? 0)
                    digits += 1
                    index += 1
                }
                result.append(value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}")
                // One whitespace after the digits ends the escape; "\r\n" counts as one.
                if index < scalars.count, [" ", "\t", "\n", "\r", "\u{0C}"].contains(scalars[index]) {
                    index += scalars[index] == "\r" && index + 1 < scalars.count && scalars[index + 1] == "\n" ? 2 : 1
                }
            }
            return String(result)
        }

        /// The text split at semicolons outside quotes and brackets, so a `;` inside
        /// `url("a;b")` does not end a declaration.
        static func split(_ text: String) -> [String] {
            var parts: [String] = []
            var current = ""
            var quote: Character?
            var depth = 0
            var escaped = false
            for character in text {
                if escaped { escaped = false; current.append(character); continue }
                if character == "\\" { escaped = true; current.append(character); continue }
                if let open = quote {
                    // A line break ends a string too (CSS makes it a bad string).
                    if character == open || character.isNewline { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "(" || character == "[" {
                    depth += 1
                } else if character == ")" || character == "]" {
                    depth = max(0, depth - 1)
                } else if character == ";", depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
                current.append(character)
            }
            parts.append(current)
            return parts
        }

        /// The text without `/* … */` comments (an unclosed one runs to the end). As CSS reads
        /// it, `/*` in a quoted string (`url("/*")`) or after a backslash (`\/*`) starts no
        /// comment: strings and escapes are read as `split` reads them, and a string also ends
        /// at a line break.
        static func strippingComments(_ text: String) -> String {
            let characters = Array(text)
            var result = ""
            var quote: Character?
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "\\" {
                    // An escape: the backslash and the character after it, whatever that is.
                    result.append(character)
                    if index + 1 < characters.count { result.append(characters[index + 1]) }
                    index += 2
                    continue
                }
                if let open = quote {
                    if character == open || character.isNewline { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    var close = index + 2
                    while close + 1 < characters.count, !(characters[close] == "*" && characters[close + 1] == "/") {
                        close += 1
                    }
                    guard close + 1 < characters.count else { return result }
                    result += " "
                    index = close + 2
                    continue
                }
                result.append(character)
                index += 1
            }
            return result
        }
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// PDF text through PDFKit, with line breaks reflowed into paragraphs.
public enum PDFReader {
    static func document(_ url: URL) throws -> ReadableDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a readable PDF.")
        }
        guard !pdf.isLocked else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is password-protected.")
        }
        var pages: [String] = []
        for index in 0..<pdf.pageCount {
            // A long PDF read for a reading that was stopped ends here (outside a task, never).
            try Task.checkCancellation()
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
    static func document(_ url: URL, type: NSAttributedString.DocumentType) throws -> ReadableDocument {
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
