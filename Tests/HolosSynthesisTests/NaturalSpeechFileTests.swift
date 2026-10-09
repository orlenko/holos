import Foundation
import HolosCore
import Testing
@testable import HolosSynthesis

// The speech file writer (`NaturalSpeechFileWriter`): what it counts, and that a finished writer takes no more.

@Suite final class NaturalSpeechFileTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-writer-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func aFinishedWriterTakesNoMoreSamples() throws {
        let writer = try NaturalSpeechFileWriter(url: root.appendingPathComponent("w.caf"), sampleRate: 24_000)
        try writer.append([Float](repeating: 0.1, count: 100))
        try writer.appendSilence(seconds: 0.01)
        #expect(writer.frames == 340)
        writer.close()
        writer.close()
        #expect(throws: HolosError.self) { try writer.append([0.1]) }
        #expect(writer.frames == 340)
    }
}
