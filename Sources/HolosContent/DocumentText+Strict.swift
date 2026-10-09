import Foundation
import HolosCore

/// Strict text reading for `voiceislocal say --text-file`: a regular file only, bounded, read until its end, and
/// decoded without repair.
extension DocumentText {
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

    /// The text of the file at `url` (`voiceislocal say --text-file`): opened only as a regular file (a FIFO or a
    /// device such as /dev/zero is refused at once, never read), read up to `maximumBytes`, and decoded strictly
    /// (`decodeStrictly`). Fails for a larger file, one that is not text, or one with nothing to read.
    public static func readTextFile(_ url: URL, maximumBytes: Int) throws -> String {
        let handle: FileHandle
        do {
            handle = try openRegularFile(url)
        } catch let error as ReadingFileError {
            throw HolosError.invalidInput(error.message)
        }
        defer { try? handle.close() }
        let data = try readUpTo(handle, maximumBytes + 1)
        guard data.count <= maximumBytes else {
            throw HolosError.invalidInput("\(url.path) is larger than \(maximumBytes / (1 << 20)) MB.")
        }
        guard let text = decodeStrictly(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("\(url.path) is empty or is not UTF-8 text.")
        }
        return text
    }

    /// Up to `limit` bytes of `handle`, read until its end or `limit`: one read may return fewer bytes than asked
    /// before the end (a network volume).
    static func readUpTo(_ handle: FileHandle, _ limit: Int) throws -> Data {
        try readUpTo(limit) { try handle.read(upToCount: $0) }
    }

    /// `readUpTo` with the reads given: `read(n)` returns at most `n` bytes, nil or none at the end.
    static func readUpTo(_ limit: Int, read: (Int) throws -> Data?) throws -> Data {
        var data = Data()
        while data.count < limit {
            guard let chunk = try read(limit - data.count), !chunk.isEmpty else { break }
            data.append(chunk.prefix(limit - data.count))
        }
        return data
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
}
