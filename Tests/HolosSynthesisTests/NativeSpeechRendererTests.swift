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

/// The rendered file is published through `ExclusivePublisher`: on a volume that can neither
/// rename exclusively nor hard-link (exFAT), it is copied into a file created exclusively.
@Test func renderPublishesWithoutExclusiveRenameOrHardLinks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holos-publish-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let unsupported: ExclusivePublisher.ExclusiveRename = { _, _ in errno = ENOTSUP; return -1 }
    for ext in ["caf", "wav", "m4a"] {
        let output = directory.appendingPathComponent("part.\(ext)")
        let result = try await publish(frames: 2_205, to: output, exclusiveRename: unsupported)
        #expect(result.url == output)
        #expect(result.frameCount == 2_205)
        #expect(try AVAudioFile(forReading: output).length > 0)
        // Only the published file is left: the temporaries are gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [output.lastPathComponent], "\(ext)")
        try FileManager.default.removeItem(at: output)
    }

    // A file that appears at the output before the copy is kept, and nothing is left behind.
    let output = directory.appendingPathComponent("taken.caf")
    let sentinel = Data("keep".utf8)
    let late: ExclusivePublisher.ExclusiveRename = { _, destination in
        FileManager.default.createFile(atPath: destination, contents: sentinel)
        errno = ENOTSUP
        return -1
    }
    await #expect(throws: HolosError.self) { try await publish(frames: 100, to: output, exclusiveRename: late) }
    #expect(try Data(contentsOf: output) == sentinel)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [output.lastPathComponent])

    // The whole renderer, with a real voice, publishes the same way.
    let voice = try #require(NativeSpeechRenderer.voices().first { $0.language == "en-US" })
    let spoken = directory.appendingPathComponent("spoken.caf")
    let rendered = try await NativeSpeechRenderer(exclusiveRename: unsupported)
        .render(text: "Hello.", voiceIdentifier: voice.id, to: spoken)
    #expect(rendered.url == spoken)
    #expect(try AVAudioFile(forReading: spoken).length > 0)
}

/// Cancelling the render during the fallback copy stops the copy, even though the copy runs on
/// the thread finishing the render (the synthesizer's delegate callback), not the awaiting task:
/// `cancel()` returns while the copy is paused mid-way, the copy then stops at its next chunk,
/// the render fails with `CancellationError`, and neither the partial output nor the temporary
/// file is left.
@Test(.timeLimit(.minutes(1))) func cancellingDuringTheFallbackCopyStopsItAndLeavesNothing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holos-cancel-copy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("part.wav")
    let unsupported: ExclusivePublisher.ExclusiveRename = { _, _ in errno = ENOTSUP; return -1 }

    final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var operation: RenderOperation?
        var events: [String] = []
        var outputExistedMidCopy = false
        func record(_ event: String) { lock.withLock { events.append(event) } }
    }
    let probe = Probe()
    // After the first chunk, the copy waits (holding no lock of the operation's) while another
    // thread cancels; it goes on only once `cancel()` has returned.
    let pacing = ExclusivePublisher.CopyPacing(chunkSize: 256) { chunk in
        probe.record("chunk \(chunk)")
        guard chunk == 1 else { return }
        probe.outputExistedMidCopy = FileManager.default.fileExists(atPath: output.path)
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            probe.lock.withLock { probe.operation }?.cancel()
            probe.record("cancel returned")
            cancelled.signal()
        }
        // A deadlock guard, not a timing assertion: a `cancel()` that waited for the copy would
        // never signal.
        if cancelled.wait(timeout: .now() + 30) == .timedOut { probe.record("cancel blocked") }
    }

    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
    buffer.frameLength = 22_050
    let operation = RenderOperation(
        synthesizer: AVSpeechSynthesizer(), utterance: AVSpeechUtterance(string: "Hello"),
        temporary: directory.appendingPathComponent(".holos-\(UUID().uuidString).wav"),
        output: output, fileExtension: "wav", exclusiveRename: unsupported, copyPacing: pacing)
    defer { operation.releaseSynthesizer() }
    probe.lock.withLock { probe.operation = operation }
    nonisolated(unsafe) let pcm = buffer
    // Finished off the awaiting task, as the delegate's callback finishes a real render.
    let finished = Task.detached {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RenderedAudio, Error>) in
            guard operation.start(continuation: continuation) else { return }
            operation.accept(pcm)
            DispatchQueue.global().async { operation.finish() }
        }
    }
    await #expect(throws: CancellationError.self) { try await finished.value }
    let events = probe.lock.withLock { probe.events }
    #expect(events == ["chunk 1", "cancel returned"])
    #expect(probe.outputExistedMidCopy)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

/// Feeds a render operation `frames` frames of silence and finishes it, as the synthesizer does.
private func publish(frames: AVAudioFrameCount, to output: URL,
                     exclusiveRename: @escaping ExclusivePublisher.ExclusiveRename) async throws -> RenderedAudio {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let ext = output.pathExtension
    let operation = RenderOperation(
        synthesizer: AVSpeechSynthesizer(), utterance: AVSpeechUtterance(string: "Hello"),
        temporary: output.deletingLastPathComponent()
            .appendingPathComponent(".holos-\(UUID().uuidString).\(ext == "m4a" ? "caf" : ext)"),
        output: output, fileExtension: ext, exclusiveRename: exclusiveRename)
    defer { operation.releaseSynthesizer() }
    return try await withCheckedThrowingContinuation { continuation in
        guard operation.start(continuation: continuation) else { return }
        operation.accept(buffer)
        operation.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func cancelledRenderKeepsDelegateUntilTerminalCallback() async throws {
    // AVSpeechSynthesizer does not retain its delegate, and TextToSpeech keeps messaging it
    // after a cancel. Freeing the delegate at cancellation crashed in objc_retain, as does
    // reading synthesizer.delegate below if the delegate has been freed.
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: "Hello")
    let directory = FileManager.default.temporaryDirectory
    let output = directory.appendingPathComponent("holos-test-\(UUID().uuidString).wav")
    RenderOperation(synthesizer: synthesizer, utterance: utterance,
                    temporary: directory.appendingPathComponent(".holos-test-\(UUID().uuidString).wav"),
                    output: output, fileExtension: "wav").cancel()
    weak let delegate = synthesizer.delegate
    #expect(delegate != nil)
    synthesizer.delegate?.speechSynthesizer?(synthesizer, didCancel: utterance)
    while delegate != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
}
