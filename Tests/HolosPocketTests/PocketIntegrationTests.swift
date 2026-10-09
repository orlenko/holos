import AVFAudio
import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosPocket

/// The real Pocket TTS model: opt-in, so `./scripts/test.sh` stays offline. Run with the English pack installed
/// (`voiceislocal setup --natural-voices`) and
///
///     HOLOS_POCKET_INTEGRATION=1 HOLOS_POCKET_MODELS_DIR=<models folder> HOLOS_POCKET_OUTPUT=<folder> \
///         ./scripts/test.sh --filter PocketIntegrationTests
///
/// It renders a short made-up paragraph twice (the same seed must give the same samples) into `HOLOS_POCKET_OUTPUT`
/// (else a temporary folder) and prints the render time and real-time factor. Nothing is played.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_POCKET_INTEGRATION"] == "1"))
@MainActor struct PocketIntegrationTests {
    @Test func rendersAParagraphWithAlba() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = NaturalVoiceModels.root
        try #require(NaturalVoiceModels.status(root: root, pack: .english) == .installed,
                     "Install the English pack first: voiceislocal setup --natural-voices")
        let folder = environment["HOLOS_POCKET_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("holos-pocket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backend = PocketSpeechBackend(root: root)
        let loadStart = ContinuousClock.now
        try await backend.load(.english)
        let load = ContinuousClock.now - loadStart
        let renderer = NaturalSpeechRenderer(backend: backend, checker: nil, fallback: NativeParagraphFallback(),
                                             installedPacks: { [.english] })
        let text = """
            The Tide Clock

            Every evening the ferry captain wound a brass clock that showed the tides instead of the hours. \
            Passengers liked to guess when the water would turn, and she kept a small chalkboard with the winners.
            """
        let output = folder.appendingPathComponent("pocket-integration-\(UUID().uuidString).wav")
        let start = ContinuousClock.now
        let result = try await renderer.render(text: text, voiceIdentifier: "pocket:en:alba", rate: nil, to: output)
        let elapsed = ContinuousClock.now - start
        #expect(result.duration > 3)
        #expect(try AVAudioFile(forReading: output).length == result.frameCount)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "Pocket integration: load %@, %.2f s of audio in %.2f s (%.2f× real time) -> %@",
                     "\(load)", result.duration, seconds, result.duration / seconds, output.path))
        // The same paragraph and seed give the same take.
        let voice = NaturalVoiceCatalog.defaultVoice(for: .english)
        let first = try await backend.synthesize("The water turned at seven.", voice: voice, seed: 7)
        let second = try await backend.synthesize("The water turned at seven.", voice: voice, seed: 7)
        #expect(first == second)
    }
}
