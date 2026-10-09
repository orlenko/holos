import Foundation
import HolosCore
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosSynthesis

// One render at a time per renderer, and a reading's saved fallback voice never replaced silently.

/// A backend that holds its first take until the test opens it.
private actor GatedBackend: NaturalSpeechBackend {
    private let entered: @Sendable () -> Void
    private let isOpen: @Sendable () -> Bool

    init(entered: @escaping @Sendable () -> Void, isOpen: @escaping @Sendable () -> Bool) {
        self.entered = entered
        self.isOpen = isOpen
    }

    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        entered()
        while !isOpen() { try await Task.sleep(for: .milliseconds(5)) }
        return [Float](repeating: 0.25, count: 2_400)
    }
}

@MainActor private final class UnusedFallback: ParagraphFallback {
    func defaultVoice(language: String) -> String? { nil }

    func samples(for text: String, voice: String?, language: String, sampleRate: Double) async throws
        -> (samples: [Float], voice: String) {
        throw HolosError.io("not expected")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) final class NaturalSpeechRendererInvariantTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-once-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func aSecondRenderWhileOneRunsIsRefused() async throws {
        let entered = Mutex(false), open = Mutex(false)
        let backend = GatedBackend(entered: { entered.withLock { $0 = true } }, isOpen: { open.withLock { $0 } })
        let renderer = NaturalSpeechRenderer(backend: backend, checker: nil, fallback: UnusedFallback(),
                                             installedPacks: { [.english] })
        let first = Task { @MainActor in
            try await renderer.render(text: "The first part.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                      to: self.root.appendingPathComponent("a.caf"))
        }
        #expect(await eventually { entered.withLock { $0 } })
        let error = await #expect(throws: HolosError.self) {
            _ = try await renderer.render(text: "The second part.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                          to: self.root.appendingPathComponent("b.caf"))
        }
        #expect(error?.localizedDescription.contains("already rendering") == true)
        open.withLock { $0 = true }
        _ = try await first.value
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.caf").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.caf").path))
        // Once it has ended, the next render runs.
        _ = try await renderer.render(text: "The second part.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                      to: root.appendingPathComponent("b.caf"))
    }

    @Test func aRenderThatFailsToPublishLeavesTheLastStats() async throws {
        let failing = Mutex(false)
        let renderer = NaturalSpeechRenderer(
            backend: GatedBackend(entered: {}, isOpen: { true }), checker: nil, fallback: UnusedFallback(),
            installedPacks: { [.english] },
            exclusiveRename: { from, to in
                guard failing.withLock({ $0 }) else { return renamex_np(from, to, UInt32(RENAME_EXCL)) }
                errno = EEXIST
                return -1
            })
        _ = try await renderer.render(text: "One.\n\nTwo.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                      to: root.appendingPathComponent("a.caf"))
        #expect(renderer.lastStats.paragraphs == 2)
        // Another process takes the output while this render writes: nothing is published, and the stats stay.
        failing.withLock { $0 = true }
        await #expect(throws: HolosError.self) {
            _ = try await renderer.render(text: "One.\n\nTwo.\n\nThree.", voiceIdentifier: "pocket:en:alba",
                                          rate: nil, to: self.root.appendingPathComponent("b.caf"))
        }
        #expect(renderer.lastStats.paragraphs == 2)
    }

    @Test func aSavedFallbackVoiceThatIsGoneIsSaid() async throws {
        let fallback = NativeParagraphFallback(temporaryRoot: root)
        let error = await #expect(throws: HolosError.self) {
            _ = try await fallback.samples(for: "A paragraph.", voice: "com.example.voice.gone", language: "en",
                                           sampleRate: 24_000)
        }
        #expect(error?.localizedDescription.contains("com.example.voice.gone") == true)
    }
}
