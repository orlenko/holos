import Foundation
import HolosCore
import HolosSynthesis

@MainActor public protocol ReadingAudioRenderer {
    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio
    /// Fails unless the renderer can speak with the voice `identifier`. Checked before a reading
    /// creates anything.
    func checkVoice(_ identifier: String) throws
    /// The settings a reading with `voiceIdentifier` saves when it starts (`ReadingManifest.rendererSettings`).
    func renderSettings(for voiceIdentifier: String) -> [String: String]?
    /// `render` with the settings the reading saved (nil: the renderer's current ones).
    func render(text: String, voiceIdentifier: String?, rate: Float?, savedSettings: [String: String]?,
                to output: URL) async throws -> RenderedAudio
}

extension ReadingAudioRenderer {
    /// A renderer that cannot tell which voices it has accepts every one here; `render` fails
    /// for one it lacks.
    public func checkVoice(_ identifier: String) throws {}

    /// A renderer with nothing to save.
    public func renderSettings(for voiceIdentifier: String) -> [String: String]? { nil }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, savedSettings: [String: String]?,
                       to output: URL) async throws -> RenderedAudio {
        try await render(text: text, voiceIdentifier: voiceIdentifier, rate: rate, to: output)
    }
}

extension NativeSpeechRenderer: ReadingAudioRenderer {}

extension NaturalSpeechRenderer: ReadingAudioRenderer {
    public func renderSettings(for voiceIdentifier: String) -> [String: String]? {
        settings(for: voiceIdentifier)?.values
    }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, savedSettings: [String: String]?,
                       to output: URL) async throws -> RenderedAudio {
        try await render(text: text, voiceIdentifier: voiceIdentifier, rate: rate,
                         settings: savedSettings.map(NaturalRenderSettings.init(values:)), to: output)
    }
}

/// Reads with a natural voice ("pocket:…", see `NaturalVoiceCatalog`) through `natural`, and with any other voice
/// through `system` (Apple's voices).
@MainActor public final class RoutingSpeechRenderer: ReadingAudioRenderer {
    private let system: any ReadingAudioRenderer
    private let natural: any ReadingAudioRenderer

    public init(system: any ReadingAudioRenderer = NativeSpeechRenderer(), natural: any ReadingAudioRenderer) {
        self.system = system
        self.natural = natural
    }

    private func renderer(for identifier: String?) -> any ReadingAudioRenderer {
        identifier.map(NaturalVoiceCatalog.isNatural) == true ? natural : system
    }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio {
        try await renderer(for: voiceIdentifier).render(text: text, voiceIdentifier: voiceIdentifier, rate: rate,
                                                        to: output)
    }

    public func checkVoice(_ identifier: String) throws {
        try renderer(for: identifier).checkVoice(identifier)
    }

    public func renderSettings(for voiceIdentifier: String) -> [String: String]? {
        renderer(for: voiceIdentifier).renderSettings(for: voiceIdentifier)
    }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, savedSettings: [String: String]?,
                       to output: URL) async throws -> RenderedAudio {
        try await renderer(for: voiceIdentifier).render(text: text, voiceIdentifier: voiceIdentifier, rate: rate,
                                                        savedSettings: savedSettings, to: output)
    }
}

@MainActor public protocol ReadingAudioJoiner {
    func join(parts: [AudioBookPart], metadata: AudioBookMetadata, to output: URL) async throws -> AudioBookSummary
}

public struct AudioBookJoiner: ReadingAudioJoiner {
    public init() {}
    public func join(parts: [AudioBookPart], metadata: AudioBookMetadata,
                     to output: URL) async throws -> AudioBookSummary {
        try await AudioBookWriter.write(parts: parts, metadata: metadata, to: output)
    }
}
