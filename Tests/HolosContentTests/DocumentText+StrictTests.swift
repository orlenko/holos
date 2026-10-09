import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

@Suite struct StrictTextDecodingTests {
    @Test func malformedBytesAreRefusedAndAByteOrderMarkIsDropped() {
        #expect(DocumentText.decodeStrictly(Data("Garden\r\nPath".utf8)) == "Garden\nPath")
        #expect(DocumentText.decodeStrictly(Data([0xEF, 0xBB, 0xBF]) + Data("Café".utf8)) == "Café")
        #expect(DocumentText.decodeStrictly(Data([0x47, 0x61, 0xFF, 0x72])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0xEF, 0xBB, 0xBF, 0x47, 0xC3])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])) == "Hi")
    }

    @Test func markedUTF16AndUTF32AreDecodedStrictlyToo() {
        // Well formed: little and big endian, a surrogate pair, CRLF made LF.
        #expect(DocumentText.decodeStrictly(Data([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])) == "Hi")
        #expect(DocumentText.decodeStrictly(Data([0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE])) == "😀")
        #expect(DocumentText.decodeStrictly(Data([0xFF, 0xFE, 0x41, 0x00, 0x0D, 0x00, 0x0A, 0x00, 0x42, 0x00])) == "A\nB")
        #expect(DocumentText.decodeStrictly(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41])) == "A")
        // A truncated code unit, an unpaired surrogate, a value past U+10FFFF, a lone UTF-32 surrogate.
        #expect(DocumentText.decodeStrictly(Data([0xFF, 0xFE, 0x41, 0x00, 0x42])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0xFF, 0xFE, 0x41, 0x00, 0x00, 0xD8, 0x42, 0x00])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x11, 0x00, 0x00])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0xD8, 0x00])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x41])) == nil)
    }
}

@Suite struct ShortReadTests {
    @Test func readingGoesOnUntilTheLimitWhenAReadReturnsLess() throws {
        // A pipe hands out at most its buffer (16–64 KB) per read, as a network volume may return less than asked.
        let pipe = Pipe()
        let size = 150_001
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: bytes)
            try? writer.close()
        }
        let reader = pipe.fileHandleForReading
        #expect(try DocumentText.readUpTo(reader, size + 1) == bytes)
    }

    @Test func readsThatReturnLessAreRepeatedUntilTheEndOrTheLimit() throws {
        let bytes = Data((0..<1_000).map { UInt8($0 % 251) })
        // A file system that hands out 64 bytes per read.
        func reads() -> (Int) -> Data? {
            var offset = 0
            return { wanted in
                let count = min(64, wanted, bytes.count - offset)
                defer { offset += count }
                return count > 0 ? bytes.subdata(in: offset..<(offset + count)) : nil
            }
        }
        #expect(try DocumentText.readUpTo(1_001, read: reads()) == bytes)
        #expect(try DocumentText.readUpTo(500, read: reads()) == bytes.prefix(500))
    }
}

@Suite struct TextFileReadingTests {
    @Test func onlyARegularFileIsReadAndOnlyUpToTheLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-textfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("part.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("Hello there.\r\n".utf8)).write(to: text)
        #expect(try DocumentText.readTextFile(text, maximumBytes: 1_000) == "Hello there.\n")
        // A device that never ends and a FIFO with no writer are refused at once, never read.
        #expect(throws: HolosError.self) { try DocumentText.readTextFile(URL(fileURLWithPath: "/dev/zero"), maximumBytes: 1_000) }
        let fifo = folder.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: HolosError.self) { try DocumentText.readTextFile(fifo, maximumBytes: 1_000) }
        // Larger than the limit, malformed, or empty.
        let large = folder.appendingPathComponent("large.txt")
        try Data(repeating: 0x41, count: 1_001).write(to: large)
        #expect(throws: HolosError.self) { try DocumentText.readTextFile(large, maximumBytes: 1_000) }
        try Data([0x41, 0xFF]).write(to: large)
        #expect(throws: HolosError.self) { try DocumentText.readTextFile(large, maximumBytes: 1_000) }
        try Data("  \n".utf8).write(to: large)
        #expect(throws: HolosError.self) { try DocumentText.readTextFile(large, maximumBytes: 1_000) }
    }
}
