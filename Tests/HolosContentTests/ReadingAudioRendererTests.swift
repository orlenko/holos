import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

/// A renderer that records what it is asked.
@MainActor private final class RecordingRenderer: ReadingAudioRenderer {
    let name: String
    private(set) var rendered: [String?] = []
    private(set) var checked: [String] = []

    init(_ name: String) { self.name = name }

    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL) async throws -> RenderedAudio {
        rendered.append(voiceIdentifier)
        return RenderedAudio(url: output, duration: 1, frameCount: 24_000, sampleRate: 24_000)
    }

    func checkVoice(_ identifier: String) throws {
        checked.append(identifier)
    }
}

@MainActor @Suite struct RoutingSpeechRendererTests {
    @Test func naturalVoicesGoToTheNaturalRendererAndTheRestToTheSystemOne() async throws {
        let system = RecordingRenderer("system"), natural = RecordingRenderer("natural")
        let routing = RoutingSpeechRenderer(system: system, natural: natural)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("unused.caf")
        _ = try await routing.render(text: "Hi.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output)
        _ = try await routing.render(text: "Hi.", voiceIdentifier: "com.apple.voice.premium.en-US.Ava", rate: nil,
                                     to: output)
        _ = try await routing.render(text: "Hi.", voiceIdentifier: nil, rate: nil, to: output)
        try routing.checkVoice("pocket:fr:estelle")
        try routing.checkVoice("com.apple.voice.premium.en-US.Ava")
        #expect(natural.rendered == ["pocket:en:alba"])
        #expect(system.rendered == ["com.apple.voice.premium.en-US.Ava", nil])
        #expect(natural.checked == ["pocket:fr:estelle"])
        #expect(system.checked == ["com.apple.voice.premium.en-US.Ava"])
    }
}
