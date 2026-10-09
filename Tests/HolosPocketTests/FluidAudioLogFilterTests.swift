import Foundation
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosPocket

// FluidAudio's quiet lines, which carry the text it speaks, never reach stderr; everything else does.

@Suite struct FluidAudioLogFilterTests {
    @Test func quietFluidAudioLinesAreDroppedAndTheRestKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("holos-log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let filter = try #require(FluidAudioLogFilter.install(on: descriptor))
        let lines = [
            "[19:20:09.487] [INFO] [FluidAudio.PocketTtsSession] Session chunk 0: 'The keeper hid the key.'\n",
            "Paragraph 2 is read by Ava: it was heard wrong.\n",
            "[19:20:09.500] [DEBUG] [FluidAudio.PocketTtsSynthesizer] synthesizing 'The keeper hid the key.'\n",
            "[19:20:09.600] [WARN] [FluidAudio.PocketTtsModelStore] A model was compiled again.\n",
            "Error: The voice broke.",
        ]
        for line in lines { _ = line.withCString { write(descriptor, $0, strlen($0)) } }
        filter.finish()
        filter.finish()
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(!written.contains("The keeper hid the key."))
        #expect(written == lines[1] + lines[3] + lines[4])
        // The descriptor writes to the file again.
        _ = "after\n".withCString { write(descriptor, $0, strlen($0)) }
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("after\n"))
    }
}
