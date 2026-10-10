import Foundation

extension HTMLReader {
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
}
