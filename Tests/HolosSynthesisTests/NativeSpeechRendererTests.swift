import AVFAudio
import Foundation
import HolosCore
import Testing
@testable import HolosSynthesis

@MainActor @Suite(.serialized) struct NativeSpeechRendererTests {
@Test func voicesHaveStableIdentifiers() {
    let voices = NativeSpeechRenderer.voices()
    #expect(!voices.isEmpty)
    #expect(voices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty && !$0.language.isEmpty })
    #expect(voices.contains { $0.language.hasPrefix("en") })
}

@Test func unknownVoiceFailsWithoutOutput() async throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("holos-test-\(UUID().uuidString).wav")
    await #expect(throws: HolosError.self) {
        try await NativeSpeechRenderer().render(text: "Hello", voiceIdentifier: "no.such.voice", to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func existingOutputIsPreserved() async throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("holos-test-\(UUID().uuidString).wav")
    let sentinel = Data("keep".utf8)
    try sentinel.write(to: output)
    defer { try? FileManager.default.removeItem(at: output) }
    await #expect(throws: HolosError.self) {
        try await NativeSpeechRenderer().render(text: "Hello", to: output)
    }
    #expect(try Data(contentsOf: output) == sentinel)
}

@Test func nativeBufferExportProducesReadableAudio() async throws {
    let voice = try #require(NativeSpeechRenderer.voices().first { $0.language == "en-US" })
    for ext in ["wav", "caf", "m4a"] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-test-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await NativeSpeechRenderer().render(text: "Hello from Holos.",
                                                              voiceIdentifier: voice.id, to: output)
        #expect(result.frameCount > 0)
        #expect(result.duration > 0)
        #expect(result.sampleRate > 0)
        #expect(result.url == output)
        let file = try AVAudioFile(forReading: output)
        #expect(file.length > 0)
    }
}

@Test func cancellingRenderDoesNotPublishOutput() async throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("holos-test-\(UUID().uuidString).wav")
    let task = Task {
        try await NativeSpeechRenderer().render(text: String(repeating: "Hello. ", count: 200), to: output)
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
}
