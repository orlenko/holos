import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosPocket

/// The real Pocket TTS model: opt-in, so `./scripts/test.sh` stays offline. Run with the English pack installed
/// (`voiceislocal setup --natural-voices`) and
///
///     HOLOS_POCKET_INTEGRATION=1 HOLOS_POCKET_MODELS_DIR=<models folder> ./scripts/test.sh --filter PocketIntegrationTests
///
/// It speaks a short made-up sentence twice with the same seed (the samples must be the same) and prints the load
/// time. Nothing is played or saved.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_POCKET_INTEGRATION"] == "1"))
struct PocketIntegrationTests {
    @Test func speaksWithAlbaTheSameWayTwice() async throws {
        let root = NaturalVoiceModels.root
        try #require(NaturalVoiceModels.status(root: root, pack: .english) == .installed,
                     "Install the English pack first: voiceislocal setup --natural-voices")
        let backend = PocketSpeechBackend(root: root)
        let start = ContinuousClock.now
        try await backend.load(.english)
        print("Pocket integration: load \(ContinuousClock.now - start)")
        let voice = NaturalVoiceCatalog.defaultVoice(for: .english)
        let first = try await backend.synthesize("The water turned at seven.", voice: voice, seed: 7)
        let second = try await backend.synthesize("The water turned at seven.", voice: voice, seed: 7)
        #expect(first.count > Int(NaturalSpeechFormat.sampleRate / 2))
        #expect(first == second)
    }
}
