import Foundation

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
