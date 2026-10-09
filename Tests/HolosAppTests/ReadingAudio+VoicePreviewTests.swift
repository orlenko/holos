import AppKit
import Foundation
@testable import HolosContent
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// ▶ Preview with a natural voice (`VoicePreview`): the sample is made by a fake, and nothing is played.
@MainActor @Suite struct VoicePreviewTests {
    @Test func previewOfAutomaticUsesTheVoiceMakeAudioWouldUse() async throws {
        let preview = VoicePreview()
        let asked = Mutex<[String]>([])
        preview.installedPacks = { [.english] }
        preview.preferredLanguage = { "en-CA" }
        // The sample is never made (nor played): the render fails once it is asked for.
        preview.renderNatural = { _, voice, _, _ in
            asked.withLock { $0.append(voice) }
            throw HolosError.io("not rendered in tests")
        }
        let failed = Mutex(false)
        preview.onError = { _ in failed.withLock { $0 = true } }
        preview.speak(voiceIdentifier: nil, speed: 1)
        #expect(await eventually { failed.withLock { $0 } })
        #expect(asked.withLock { $0 } == ["pocket:en:alba"])
        #expect(!preview.isSpeaking)
        #expect(ReadingVoices.automatic(language: "fr-CA", installed: [.english], bestApple: { _ in nil }) == nil)
        #expect(ReadingVoices.automatic(language: "fr-CA", installed: [.english, .french], bestApple: { _ in nil })?.id
            == "pocket:fr:estelle")
    }

    private final class FakePlayback: PreviewPlayback {
        var stopped = false
        func stop() { stopped = true }
    }

    private func previewWithMadeSample() -> VoicePreview {
        let preview = VoicePreview()
        preview.installedPacks = { [.english] }
        preview.preferredLanguage = { "en-CA" }
        // The sample is written as the tool would; nothing is played (the playback is replaced below).
        preview.renderNatural = { _, _, _, output in
            try NaturalSpeechFile.write([Float](repeating: 0, count: 2_400), sampleRate: 24_000, to: output)
        }
        return preview
    }

    @Test func aSampleThatDoesNotStartPlayingIsAFailureNotAStop() async throws {
        let preview = previewWithMadeSample()
        preview.startPlayback = { _, _ in throw HolosError.io("The voice sample could not be played.") }
        let problem = Mutex<String?>(nil)
        preview.onError = { message in problem.withLock { $0 = message } }
        preview.speak(voiceIdentifier: "pocket:en:alba", speed: 1)
        #expect(preview.isSpeaking)
        #expect(await eventually { problem.withLock { $0 } != nil })
        #expect(problem.withLock { $0 }?.contains("could not be played") == true)
        #expect(!preview.isSpeaking)
    }

    @Test func aSampleThatStartsPlayingCanBeStopped() async throws {
        let preview = previewWithMadeSample()
        let playback = FakePlayback()
        let started = Mutex(false)
        preview.startPlayback = { _, _ in
            started.withLock { $0 = true }
            return playback
        }
        preview.speak(voiceIdentifier: "pocket:en:alba", speed: 1)
        #expect(await eventually { started.withLock { $0 } })
        #expect(preview.isSpeaking)
        preview.stop()
        #expect(playback.stopped)
        #expect(!preview.isSpeaking)
    }
}
